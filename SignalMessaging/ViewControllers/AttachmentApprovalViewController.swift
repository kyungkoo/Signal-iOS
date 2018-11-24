//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer
import PromiseKit

@objc
public protocol AttachmentApprovalViewControllerDelegate: class {
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didApproveAttachments attachments: [SignalAttachment], messageText: String?)
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didCancelAttachments attachments: [SignalAttachment])
    @objc optional func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, addMoreToAttachments attachments: [SignalAttachment])
    @objc optional func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, changedCaptionOfAttachment attachment: SignalAttachment)
}

class AttachmentItemCollection {
    private (set) var attachmentItems: [SignalAttachmentItem]
    init(attachmentItems: [SignalAttachmentItem]) {
        self.attachmentItems = attachmentItems
    }

    func itemAfter(item: SignalAttachmentItem) -> SignalAttachmentItem? {
        guard let currentIndex = attachmentItems.index(of: item) else {
            owsFailDebug("currentIndex was unexpectedly nil")
            return nil
        }

        let nextIndex = attachmentItems.index(after: currentIndex)

        return attachmentItems[safe: nextIndex]
    }

    func itemBefore(item: SignalAttachmentItem) -> SignalAttachmentItem? {
        guard let currentIndex = attachmentItems.index(of: item) else {
            owsFailDebug("currentIndex was unexpectedly nil")
            return nil
        }

        let prevIndex = attachmentItems.index(before: currentIndex)

        return attachmentItems[safe: prevIndex]
    }

    func remove(item: SignalAttachmentItem) {
        attachmentItems = attachmentItems.filter { $0 != item }
    }
}

class SignalAttachmentItem: Hashable {

    enum SignalAttachmentItemError: Error {
        case noThumbnail
    }

    let attachment: SignalAttachment

    init(attachment: SignalAttachment) {
        self.attachment = attachment
    }

    // MARK: 

    var captionText: String? {
        return attachment.captionText
    }

    var imageSize: CGSize = .zero

    func getThumbnailImage() -> Promise<UIImage> {
        return DispatchQueue.global().async(.promise) { () -> UIImage in
            guard let image =  self.attachment.image() else {
                throw SignalAttachmentItemError.noThumbnail
            }
            return image
        }.tap { result in
            switch result {
            case .fulfilled(let image):
                self.imageSize = image.size
            default: break
            }

        }
    }

    // MARK: Hashable

    public var hashValue: Int {
        return attachment.hashValue
    }

    // MARK: Equatable

    static func == (lhs: SignalAttachmentItem, rhs: SignalAttachmentItem) -> Bool {
        return lhs.attachment == rhs.attachment
    }
}

@objc
public enum AttachmentApprovalViewControllerMode: UInt {
    case modal
    case sharedNavigation
}

@objc
public class AttachmentApprovalViewController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    // MARK: - Properties

    private let mode: AttachmentApprovalViewControllerMode

    public weak var approvalDelegate: AttachmentApprovalViewControllerDelegate?

    // MARK: - Initializers

    @available(*, unavailable, message:"use attachment: constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    let kSpacingBetweenItems: CGFloat = 20

    @objc
    required public init(mode: AttachmentApprovalViewControllerMode,
                         attachments: [SignalAttachment]) {
        assert(attachments.count > 0)
        self.mode = mode
        let attachmentItems = attachments.map { SignalAttachmentItem(attachment: $0 )}
        self.attachmentItemCollection = AttachmentItemCollection(attachmentItems: attachmentItems)
        super.init(transitionStyle: .scroll,
                   navigationOrientation: .horizontal,
                   options: [UIPageViewControllerOptionInterPageSpacingKey: kSpacingBetweenItems])
        self.dataSource = self
        self.delegate = self
    }

    @objc
    public class func wrappedInNavController(attachments: [SignalAttachment], approvalDelegate: AttachmentApprovalViewControllerDelegate) -> OWSNavigationController {
        let vc = AttachmentApprovalViewController(mode: .modal, attachments: attachments)
        vc.approvalDelegate = approvalDelegate
        let navController = OWSNavigationController(rootViewController: vc)

        guard let navigationBar = navController.navigationBar as? OWSNavigationBar else {
            owsFailDebug("navigationBar was nil or unexpected class")
            return navController
        }
        navigationBar.makeClear()

        return navController
    }

    // MARK: - Subviews

    var galleryRailView: GalleryRailView {
        return bottomToolView.galleryRailView
    }

    var mediaMessageTextToolbar: MediaMessageTextToolbar {
        return bottomToolView.mediaMessageTextToolbar
    }

    lazy var bottomToolView: BottomToolView = {
        let isAddMoreVisible = mode == .sharedNavigation
        let bottomToolView = BottomToolView(isAddMoreVisible: isAddMoreVisible)

        return bottomToolView
    }()

    // MARK: - View Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = .black

        disablePagingIfNecessary()

        // Bottom Toolbar
        galleryRailView.delegate = self
        mediaMessageTextToolbar.mediaMessageTextToolbarDelegate = self

        // Navigation

        self.navigationItem.title = nil

        if mode != .sharedNavigation {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel,
                                               target: self, action: #selector(cancelPressed))
            cancelButton.tintColor = .white
            self.navigationItem.leftBarButtonItem = cancelButton
        }

        guard let firstItem = attachmentItems.first else {
            owsFailDebug("firstItem was unexpectedly nil")
            return
        }

        self.setCurrentItem(firstItem, direction: .forward, animated: false)

//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(keyboardWillChangeFrame(notification:)),
//                                               name: .UIKeyboardWillChangeFrame,
//                                               object: nil)

        observers = [
            NotificationCenter.default.addObserver(forName: .UIKeyboardWillShow, object: nil, queue: nil) { [weak self] notification in
                guard let strongSelf = self else { return }

                guard let userInfo = notification.userInfo else {
                    owsFailDebug("userInfo was unexpectedly nil")
                    return
                }

                guard let keyboardStartFrame = userInfo[UIKeyboardFrameBeginUserInfoKey] as? CGRect else {
                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
                    return
                }

                guard let keyboardEndFrame = userInfo[UIKeyboardFrameEndUserInfoKey] as? CGRect else {
                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
                    return
                }

                Logger.debug("UIKeyboardWillShow frame: \(keyboardStartFrame) -> \(keyboardEndFrame)")
                strongSelf.keyboardWillShow(notification: notification)
            },

//            NotificationCenter.default.addObserver(forName: .UIKeyboardDidShow, object: nil, queue: nil) { [weak self] notification in
//                guard let userInfo = notification.userInfo else {
//                    owsFailDebug("userInfo was unexpectedly nil")
//                    return
//                }
//
//                guard let keyboardStartFrame = userInfo[UIKeyboardFrameBeginUserInfoKey] as? CGRect else {
//                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
//                    return
//                }
//
//                guard let keyboardEndFrame = userInfo[UIKeyboardFrameEndUserInfoKey] as? CGRect else {
//                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
//                    return
//                }
//
//                Logger.debug("UIKeyboardDidShow frame: \(keyboardStartFrame) -> \(keyboardEndFrame)")
//            },

            NotificationCenter.default.addObserver(forName: .UIKeyboardWillHide, object: nil, queue: nil) { [weak self] notification in
                guard let strongSelf = self else { return }

                guard let userInfo = notification.userInfo else {
                    owsFailDebug("userInfo was unexpectedly nil")
                    return
                }

                guard let keyboardStartFrame = userInfo[UIKeyboardFrameBeginUserInfoKey] as? CGRect else {
                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
                    return
                }

                guard let keyboardEndFrame = userInfo[UIKeyboardFrameEndUserInfoKey] as? CGRect else {
                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
                    return
                }

                Logger.debug("UIKeyboardWillHide frame: \(keyboardStartFrame) -> \(keyboardEndFrame)")
                strongSelf.keyboardWillHide(notification: notification)
            }

//            NotificationCenter.default.addObserver(forName: .UIKeyboardDidHide, object: nil, queue: nil) { [weak self] notification in
//                guard let userInfo = notification.userInfo else {
//                    owsFailDebug("userInfo was unexpectedly nil")
//                    return
//                }
//
//                guard let keyboardStartFrame = userInfo[UIKeyboardFrameBeginUserInfoKey] as? CGRect else {
//                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
//                    return
//                }
//
//                guard let keyboardEndFrame = userInfo[UIKeyboardFrameEndUserInfoKey] as? CGRect else {
//                    owsFailDebug("keyboardEndFrame was unexpectedly nil")
//                    return
//                }
//
//                Logger.debug("UIKeyboardDidHide frame: \(keyboardStartFrame) -> \(keyboardEndFrame)")
//            },
        ]
    }

    var observers: [NSObjectProtocol] = []

    override public func viewWillAppear(_ animated: Bool) {
        Logger.debug("")
        super.viewWillAppear(animated)

        CurrentAppContext().setStatusBarHidden(true, animated: animated)
    }

    override public func viewDidAppear(_ animated: Bool) {
        Logger.debug("")

        super.viewDidAppear(animated)
    }

    override public func viewWillDisappear(_ animated: Bool) {
        Logger.debug("")
        super.viewWillDisappear(animated)

        // Since this VC is being dismissed, the "show status bar" animation would feel like
        // it's occuring on the presenting view controller - it's better not to animate at all.
        CurrentAppContext().setStatusBarHidden(false, animated: false)
    }

    override public var inputAccessoryView: UIView? {
        bottomToolView.layoutIfNeeded()
        return bottomToolView
    }

    override public var canBecomeFirstResponder: Bool {
        return true
    }

    var lastObservedKeyboardHeight: CGFloat = 0

    @objc
    func keyboardWillShow(notification: Notification) {
        guard let userInfo = notification.userInfo else {
            owsFailDebug("userInfo was unexpectedly nil")
            return
        }

        guard let keyboardStartFrame = userInfo[UIKeyboardFrameBeginUserInfoKey] as? CGRect else {
            owsFailDebug("keyboardEndFrame was unexpectedly nil")
            return
        }

        guard let keyboardEndFrame = userInfo[UIKeyboardFrameEndUserInfoKey] as? CGRect else {
            owsFailDebug("keyboardEndFrame was unexpectedly nil")
            return
        }

        Logger.debug("\(keyboardStartFrame) -> \(keyboardEndFrame)")

        lastObservedKeyboardHeight = keyboardEndFrame.size.height

        viewControllers?.forEach { viewController in
            guard let prepViewController = viewController as? AttachmentPrepViewController else {
                owsFailDebug("unexpected prepViewController: \(viewController)")
                return
            }

            prepViewController.updateCaptionViewBottomInset()
        }
    }

    @objc
    func keyboardWillHide(notification: Notification) {
        guard let userInfo = notification.userInfo else {
            owsFailDebug("userInfo was unexpectedly nil")
            return
        }

        guard let keyboardStartFrame = userInfo[UIKeyboardFrameBeginUserInfoKey] as? CGRect else {
            owsFailDebug("keyboardEndFrame was unexpectedly nil")
            return
        }

        guard let keyboardEndFrame = userInfo[UIKeyboardFrameEndUserInfoKey] as? CGRect else {
            owsFailDebug("keyboardEndFrame was unexpectedly nil")
            return
        }

        Logger.debug("\(keyboardStartFrame) -> \(keyboardEndFrame)")

        lastObservedKeyboardHeight = keyboardEndFrame.size.height
        if keyboardStartFrame.height == keyboardEndFrame.height {
            lastObservedKeyboardHeight -= keyboardEndFrame.maxY - keyboardStartFrame.maxY
        }

        viewControllers?.forEach { viewController in
            guard let prepViewController = viewController as? AttachmentPrepViewController else {
                owsFailDebug("unexpected prepViewController: \(viewController)")
                return
            }

            prepViewController.updateCaptionViewBottomInset()
        }
    }

    // MARK: - View Helpers

    func remove(attachmentItem: SignalAttachmentItem) {
        if attachmentItem == currentItem {
            if let nextItem = attachmentItemCollection.itemAfter(item: attachmentItem) {
                setCurrentItem(nextItem, direction: .forward, animated: true)
            } else if let prevItem = attachmentItemCollection.itemBefore(item: attachmentItem) {
                setCurrentItem(prevItem, direction: .reverse, animated: true)
            } else {
                owsFailDebug("removing last item shouldn't be possible because rail should not be visible")
                return
            }
        }

        guard let cell = galleryRailView.cellViews.first(where: { $0.item === attachmentItem }) else {
            owsFailDebug("cell was unexpectedly nil")
            return
        }

        UIView.animate(withDuration: 0.2,
                       animations: {
                        // shrink stack view item until it disappears
                        cell.isHidden = true

                        // simultaneously fade out
                        cell.alpha = 0
        },
                       completion: { _ in
                        self.attachmentItemCollection.remove(item: attachmentItem)
                        self.updateMediaRail()
        })
    }

    func addDeleteIcon(cellView: GalleryRailCellView) {
        guard let attachmentItem = cellView.item as? SignalAttachmentItem else {
            owsFailDebug("attachmentItem was unexpectedly nil")
            return
        }

        let button = OWSButton { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.remove(attachmentItem: attachmentItem)
        }
        button.setImage(#imageLiteral(resourceName: "ic_small_x"), for: .normal)

        let kInsetDistance: CGFloat = 5
        button.imageEdgeInsets = UIEdgeInsets(top: kInsetDistance, left: kInsetDistance, bottom: kInsetDistance, right: kInsetDistance)

        cellView.addSubview(button)

        let kButtonWidth: CGFloat = 9 + kInsetDistance * 2
        button.autoSetDimensions(to: CGSize(width: kButtonWidth, height: kButtonWidth))
        button.autoPinEdge(toSuperviewMargin: .top)
        button.autoPinEdge(toSuperviewMargin: .trailing)
    }

    var pagerScrollView: UIScrollView?
    // This is kind of a hack. Since we don't have first class access to the superview's `scrollView`
    // we traverse the view hierarchy until we find it, then disable scrolling if there's only one
    // item. This avoids an unpleasant "bounce" which doesn't make sense in the context of a single item.
    fileprivate func disablePagingIfNecessary() {
        for view in self.view.subviews {
            if let pagerScrollView = view as? UIScrollView {
                self.pagerScrollView = pagerScrollView
                break
            }
        }

        guard let pagerScrollView = self.pagerScrollView else {
            owsFailDebug("pagerScrollView was unexpectedly nil")
            return
        }

        pagerScrollView.isScrollEnabled = attachmentItems.count > 1
    }

    // MARK: - UIPageViewControllerDelegate

    public func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        Logger.debug("")

        assert(pendingViewControllers.count == 1)
        pendingViewControllers.forEach { viewController in
            guard let pendingPage = viewController as? AttachmentPrepViewController else {
                owsFailDebug("unexpected viewController: \(viewController)")
                return
            }

            // use compact scale when keyboard is popped.
            let scale: AttachmentPrepViewController.AttachmentViewScale = self.isFirstResponder ? .fullsize : .compact
            pendingPage.setAttachmentViewScale(scale, animated: false)
            pendingPage.updateCaptionViewBottomInset()
        }
    }

    public func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted: Bool) {
        Logger.debug("")

        assert(previousViewControllers.count == 1)
        previousViewControllers.forEach { viewController in
            guard let previousPage = viewController as? AttachmentPrepViewController else {
                owsFailDebug("unexpected viewController: \(viewController)")
                return
            }

            if transitionCompleted {
                previousPage.zoomOut(animated: false)
                updateMediaRail()
            }
        }
    }

    // MARK: - UIPageViewControllerDataSource

    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let currentViewController = viewController as? AttachmentPrepViewController else {
            owsFailDebug("unexpected viewController: \(viewController)")
            return nil
        }

        let currentItem = currentViewController.attachmentItem
        guard let previousItem = attachmentItem(before: currentItem) else {
            return nil
        }

        guard let previousPage: AttachmentPrepViewController = buildPage(item: previousItem) else {
            return nil
        }

        return previousPage
    }

    public func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        Logger.debug("")

        guard let currentViewController = viewController as? AttachmentPrepViewController else {
            owsFailDebug("unexpected viewController: \(viewController)")
            return nil
        }

        let currentItem = currentViewController.attachmentItem
        guard let nextItem = attachmentItem(after: currentItem) else {
            return nil
        }

        guard let nextPage: AttachmentPrepViewController = buildPage(item: nextItem) else {
            return nil
        }

        return nextPage
    }

    public var currentViewController: AttachmentPrepViewController {
        return viewControllers!.first as! AttachmentPrepViewController
    }

    var currentItem: SignalAttachmentItem! {
        get {
            return currentViewController.attachmentItem
        }
        set {
            setCurrentItem(newValue, direction: .forward, animated: false)
        }
    }

    private var cachedPages: [SignalAttachmentItem: AttachmentPrepViewController] = [:]
    private func buildPage(item: SignalAttachmentItem) -> AttachmentPrepViewController? {

        if let cachedPage = cachedPages[item] {
            Logger.debug("cache hit.")
            return cachedPage
        }

        Logger.debug("cache miss.")
        let viewController = AttachmentPrepViewController(attachmentItem: item)
        viewController.prepDelegate = self
        cachedPages[item] = viewController

        return viewController
    }

    private func setCurrentItem(_ item: SignalAttachmentItem, direction: UIPageViewControllerNavigationDirection, animated isAnimated: Bool) {
        guard let page = self.buildPage(item: item) else {
            owsFailDebug("unexpectedly unable to build new page")
            return
        }

        self.setViewControllers([page], direction: direction, animated: isAnimated, completion: nil)
        updateMediaRail()
    }

    func updateMediaRail() {
        guard let currentItem = self.currentItem else {
            owsFailDebug("currentItem was unexpectedly nil")
            return
        }

        let cellViewDecoratorBlock = { (cellView: GalleryRailCellView) in
            self.addDeleteIcon(cellView: cellView)
        }
        galleryRailView.configureCellViews(itemProvider: attachmentItemCollection,
                                           focusedItem: currentItem,
                                           cellViewDecoratorBlock: cellViewDecoratorBlock)

        galleryRailView.isHidden = attachmentItemCollection.attachmentItems.count < 2
    }

    let attachmentItemCollection: AttachmentItemCollection

    var attachmentItems: [SignalAttachmentItem] {
        return attachmentItemCollection.attachmentItems
    }

    var attachments: [SignalAttachment] {
        return attachmentItems.map { $0.attachment }
    }

    func attachmentItem(before currentItem: SignalAttachmentItem) -> SignalAttachmentItem? {
        guard let currentIndex = attachmentItems.index(of: currentItem) else {
            owsFailDebug("currentIndex was unexpectedly nil")
            return nil
        }

        let index: Int = attachmentItems.index(before: currentIndex)
        guard let previousItem = attachmentItems[safe: index] else {
            // already at first item
            return nil
        }

        return previousItem
    }

    func attachmentItem(after currentItem: SignalAttachmentItem) -> SignalAttachmentItem? {
        guard let currentIndex = attachmentItems.index(of: currentItem) else {
            owsFailDebug("currentIndex was unexpectedly nil")
            return nil
        }

        let index: Int = attachmentItems.index(after: currentIndex)
        guard let nextItem = attachmentItems[safe: index] else {
            // already at last item
            return nil
        }

        return nextItem
    }

    // MARK: - Event Handlers

    @objc func cancelPressed(sender: UIButton) {
        self.approvalDelegate?.attachmentApproval(self, didCancelAttachments: attachments)
    }
}

extension AttachmentApprovalViewController: MediaMessageTextToolbarDelegate {
    var currentPageController: AttachmentPrepViewController {
        return viewControllers!.first as! AttachmentPrepViewController
    }

    func mediaMessageTextToolbarDidBeginEditing(_ mediaMessageTextToolbar: MediaMessageTextToolbar) {
        currentPageController.setAttachmentViewScale(.compact, animated: true)
    }

    func mediaMessageTextToolbarDidEndEditing(_ mediaMessageTextToolbar: MediaMessageTextToolbar) {
        currentPageController.setAttachmentViewScale(.fullsize, animated: true)
    }

    func mediaMessageTextToolbarDidTapSend(_ mediaMessageTextToolbar: MediaMessageTextToolbar) {
        // Toolbar flickers in and out if there are errors
        // and remains visible momentarily after share extension is dismissed.
        // It's easiest to just hide it at this point since we're done with it.
        currentViewController.shouldAllowAttachmentViewResizing = false
        mediaMessageTextToolbar.isUserInteractionEnabled = false
        mediaMessageTextToolbar.isHidden = true

        approvalDelegate?.attachmentApproval(self, didApproveAttachments: attachments, messageText: mediaMessageTextToolbar.messageText)
    }

    func mediaMessageTextToolbarDidAddMore(_ mediaMessageTextToolbar: MediaMessageTextToolbar) {
        self.approvalDelegate?.attachmentApproval?(self, addMoreToAttachments: attachments)
    }
}

extension AttachmentApprovalViewController: AttachmentPrepViewControllerDelegate {
    func prepViewController(_ prepViewController: AttachmentPrepViewController, didUpdateCaptionForAttachmentItem attachmentItem: SignalAttachmentItem) {
        self.approvalDelegate?.attachmentApproval?(self, changedCaptionOfAttachment: attachmentItem.attachment)
    }

    func prepViewController(_ prepViewController: AttachmentPrepViewController, didBeginEditingCaptionView captionView: CaptionView) {
        // Disable paging while captions are being edited to avoid a clunky animation.
        //
        // Loading the next page causes the CaptionView to resign first responder, which in turn
        // dismisses the keyboard, which in turn affects the vertical offset of both the CaptionView
        // from the page we're leaving as well as the page we're entering. Instead we require the
        // user to dismiss *then* swipe.
        disablePaging()
    }

    func prepViewController(_ prepViewController: AttachmentPrepViewController, didEndEditingCaptionView captionView: CaptionView) {
        enablePaging()
    }

    var desiredCaptionViewBottomInset: CGFloat {
        // CaptionView bottom offset scenarios:
        //
        // 1. when no keyboard is popped (e.g. initially) to be *just* above the rail
        // 2. when the CaptionView becomes first responder, to be *just* above the keyboard, so the
        //    user can see what they're typing.
        //
        // For these cases we apply the observed `lastKnownBottomToolbar
        guard bottomToolView.mediaMessageTextToolbar.textView.isFirstResponder else {
            return lastObservedKeyboardHeight
        }

        // 3. when the MessageTextView becomes first responder, the keyboard should shift up
        //    "in front" of the CaptionView
        return 0
    }

    // MARK: Helpers

    func disablePaging() {
        pagerScrollView?.panGestureRecognizer.isEnabled = false
    }

    func enablePaging() {
        self.pagerScrollView?.panGestureRecognizer.isEnabled = true
    }
}

// MARK: GalleryRail

extension SignalAttachmentItem: GalleryRailItem {
    var aspectRatio: CGFloat {
        return self.imageSize.aspectRatio
    }

    func getRailImage() -> Promise<UIImage> {
        return self.getThumbnailImage()
    }
}

extension AttachmentItemCollection: GalleryRailItemProvider {
    var railItems: [GalleryRailItem] {
        return self.attachmentItems
    }
}

extension AttachmentApprovalViewController: GalleryRailViewDelegate {
    public func galleryRailView(_ galleryRailView: GalleryRailView, didTapItem imageRailItem: GalleryRailItem) {
        guard let targetItem = imageRailItem as? SignalAttachmentItem else {
            owsFailDebug("unexpected imageRailItem: \(imageRailItem)")
            return
        }

        guard let currentIndex = attachmentItems.index(of: currentItem) else {
            owsFailDebug("currentIndex was unexpectedly nil")
            return
        }

        guard let targetIndex = attachmentItems.index(of: targetItem) else {
            owsFailDebug("targetIndex was unexpectedly nil")
            return
        }

        let direction: UIPageViewControllerNavigationDirection = currentIndex < targetIndex ? .forward : .reverse

        self.setCurrentItem(targetItem, direction: direction, animated: true)
    }
}

// MARK: - Individual Page

protocol AttachmentPrepViewControllerDelegate: class {
    func prepViewController(_ prepViewController: AttachmentPrepViewController, didUpdateCaptionForAttachmentItem attachmentItem: SignalAttachmentItem)

    func prepViewController(_ prepViewController: AttachmentPrepViewController, didBeginEditingCaptionView captionView: CaptionView)
    func prepViewController(_ prepViewController: AttachmentPrepViewController, didEndEditingCaptionView captionView: CaptionView)

    var desiredCaptionViewBottomInset: CGFloat { get }
}

public class AttachmentPrepViewController: OWSViewController, PlayerProgressBarDelegate, OWSVideoPlayerDelegate {
    // We sometimes shrink the attachment view so that it remains somewhat visible
    // when the keyboard is presented.
    enum AttachmentViewScale {
        case fullsize, compact
    }

    // MARK: - Properties

    weak var prepDelegate: AttachmentPrepViewControllerDelegate?

    let attachmentItem: SignalAttachmentItem
    var attachment: SignalAttachment {
        return attachmentItem.attachment
    }

    private var videoPlayer: OWSVideoPlayer?

    private(set) var mediaMessageView: MediaMessageView!
    private(set) var scrollView: UIScrollView!
    private(set) var contentContainer: UIView!
    private(set) var playVideoButton: UIView?

    // MARK: - Initializers

    init(attachmentItem: SignalAttachmentItem) {
        self.attachmentItem = attachmentItem
        super.init(nibName: nil, bundle: nil)
        assert(!attachment.hasError)
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Subviews

    lazy var captionView: CaptionView = {
        return CaptionView(attachmentItem: attachmentItem)
    }()

    lazy var touchInterceptorView: UIView = {
        let touchInterceptorView = UIView()
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTapTouchInterceptorView(gesture:)))
        touchInterceptorView.addGestureRecognizer(tapGesture)

        return touchInterceptorView
    }()

    // MARK: - View Lifecycle

    override public func loadView() {
        self.view = UIView()

        self.mediaMessageView = MediaMessageView(attachment: attachment, mode: .attachmentApproval)

        // Anything that should be shrunk when user pops keyboard lives in the contentContainer.
        let contentContainer = UIView()
        self.contentContainer = contentContainer
        view.addSubview(contentContainer)
        contentContainer.autoPinEdgesToSuperviewEdges()

        // Scroll View - used to zoom/pan on images and video
        scrollView = UIScrollView()
        contentContainer.addSubview(scrollView)
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        // Panning should stop pretty soon after the user stops scrolling
        scrollView.decelerationRate = UIScrollViewDecelerationRateFast

        // We want scroll view content up and behind the system status bar content
        // but we want other content (e.g. bar buttons) to respect the top layout guide.
        self.automaticallyAdjustsScrollViewInsets = false

        scrollView.autoPinEdgesToSuperviewEdges()

        let backgroundColor = UIColor.black
        self.view.backgroundColor = backgroundColor

        // Create full screen container view so the scrollView
        // can compute an appropriate content size in which to center
        // our media view.
        let containerView = UIView.container()
        scrollView.addSubview(containerView)
        containerView.autoPinEdgesToSuperviewEdges()
        containerView.autoMatch(.height, to: .height, of: self.view)
        containerView.autoMatch(.width, to: .width, of: self.view)

        containerView.addSubview(mediaMessageView)
        mediaMessageView.autoPinEdgesToSuperviewEdges()

        if isZoomable {
            // Add top and bottom gradients to ensure toolbar controls are legible
            // when placed over image/video preview which may be a clashing color.
            let topGradient = GradientView(from: backgroundColor, to: UIColor.clear)
            self.view.addSubview(topGradient)
            topGradient.autoPinWidthToSuperview()
            topGradient.autoPinEdge(toSuperviewEdge: .top)
            topGradient.autoSetDimension(.height, toSize: ScaleFromIPhone5(60))
        }

        // Hide the play button embedded in the MediaView and replace it with our own.
        // This allows us to zoom in on the media view without zooming in on the button
        if attachment.isVideo {

            guard let videoURL = attachment.dataUrl else {
                owsFailDebug("Missing videoURL")
                return
            }

            let player = OWSVideoPlayer(url: videoURL)
            self.videoPlayer = player
            player.delegate = self

            let playerView = VideoPlayerView()
            playerView.player = player.avPlayer
            self.mediaMessageView.addSubview(playerView)
            playerView.autoPinEdgesToSuperviewEdges()

            let pauseGesture = UITapGestureRecognizer(target: self, action: #selector(didTapPlayerView(_:)))
            playerView.addGestureRecognizer(pauseGesture)

            let progressBar = PlayerProgressBar()
            progressBar.player = player.avPlayer
            progressBar.delegate = self

            // we don't want the progress bar to zoom during "pinch-to-zoom"
            // but we do want it to shrink with the media content when the user
            // pops the keyboard.
            contentContainer.addSubview(progressBar)

            progressBar.autoPin(toTopLayoutGuideOf: self, withInset: 0)
            progressBar.autoPinWidthToSuperview()
            progressBar.autoSetDimension(.height, toSize: 44)

            self.mediaMessageView.videoPlayButton?.isHidden = true
            let playButton = UIButton()
            self.playVideoButton = playButton
            playButton.accessibilityLabel = NSLocalizedString("PLAY_BUTTON_ACCESSABILITY_LABEL", comment: "Accessibility label for button to start media playback")
            playButton.setBackgroundImage(#imageLiteral(resourceName: "play_button"), for: .normal)
            playButton.contentMode = .scaleAspectFit

            let playButtonWidth = ScaleFromIPhone5(70)
            playButton.autoSetDimensions(to: CGSize(width: playButtonWidth, height: playButtonWidth))
            self.contentContainer.addSubview(playButton)

            playButton.addTarget(self, action: #selector(playButtonTapped), for: .touchUpInside)
            playButton.autoCenterInSuperview()
        }

        // Caption

        view.addSubview(touchInterceptorView)
        touchInterceptorView.autoPinEdgesToSuperviewEdges()
        touchInterceptorView.isHidden = true

        view.addSubview(captionView)
        captionView.delegate = self

        captionView.autoPinWidthToSuperview()
        captionViewBottomConstraint = captionView.autoPinEdge(toSuperviewMargin: .bottom)
    }

    override public func viewWillLayoutSubviews() {
        Logger.debug("")
        super.viewWillLayoutSubviews()

        // e.g. if flipping to/from landscape
        updateMinZoomScaleForSize(view.bounds.size)

        ensureAttachmentViewScale(animated: false)
    }

    // MARK: CaptionView lifts with keyboard

    var hasLaidOutCaptionView: Bool = false
    var captionViewBottomConstraint: NSLayoutConstraint!
    func updateCaptionViewBottomInset() {
        guard let prepDelegate = self.prepDelegate else {
            owsFailDebug("prepDelegate was unexpectedly nil")
            return
        }

        let changeBlock = {
            self.captionViewBottomConstraint.constant = -prepDelegate.desiredCaptionViewBottomInset
            self.captionView.superview?.layoutIfNeeded()
        }

        // To avoid an animation glitch, we apply this update without animation before initial
        // appearance. But after that, we want to apply the constraint change within the existing
        // animation context, since we call this while handling a UIKeyboard notification, which
        // allows us to slide up the CaptionView in lockstep with the keyboard.
        if hasLaidOutCaptionView {
            changeBlock()
        } else {
            hasLaidOutCaptionView = true
            UIView.performWithoutAnimation { changeBlock() }
        }
    }

    // MARK: - Event Handlers

    @objc
    func didTapTouchInterceptorView(gesture: UITapGestureRecognizer) {
        Logger.info("")
        captionView.endEditing()
        touchInterceptorView.isHidden = true
    }

    @objc
    public func didTapPlayerView(_ gestureRecognizer: UIGestureRecognizer) {
        assert(self.videoPlayer != nil)
        self.pauseVideo()
    }

    @objc
    public func playButtonTapped() {
        self.playVideo()
    }

    // MARK: - Video

    private func playVideo() {
        Logger.info("")

        guard let videoPlayer = self.videoPlayer else {
            owsFailDebug("video player was unexpectedly nil")
            return
        }

        guard let playVideoButton = self.playVideoButton else {
            owsFailDebug("playVideoButton was unexpectedly nil")
            return
        }
        UIView.animate(withDuration: 0.1) {
            playVideoButton.alpha = 0.0
        }
        videoPlayer.play()
    }

    private func pauseVideo() {
        guard let videoPlayer = self.videoPlayer else {
            owsFailDebug("video player was unexpectedly nil")
            return
        }

        videoPlayer.pause()
        guard let playVideoButton = self.playVideoButton else {
            owsFailDebug("playVideoButton was unexpectedly nil")
            return
        }
        UIView.animate(withDuration: 0.1) {
            playVideoButton.alpha = 1.0
        }
    }

    @objc
    public func videoPlayerDidPlayToCompletion(_ videoPlayer: OWSVideoPlayer) {
        guard let playVideoButton = self.playVideoButton else {
            owsFailDebug("playVideoButton was unexpectedly nil")
            return
        }

        UIView.animate(withDuration: 0.1) {
            playVideoButton.alpha = 1.0
        }
    }

    public func playerProgressBarDidStartScrubbing(_ playerProgressBar: PlayerProgressBar) {
        guard let videoPlayer = self.videoPlayer else {
            owsFailDebug("video player was unexpectedly nil")
            return
        }
        videoPlayer.pause()
    }

    public func playerProgressBar(_ playerProgressBar: PlayerProgressBar, scrubbedToTime time: CMTime) {
        guard let videoPlayer = self.videoPlayer else {
            owsFailDebug("video player was unexpectedly nil")
            return
        }

        videoPlayer.seek(to: time)
    }

    public func playerProgressBar(_ playerProgressBar: PlayerProgressBar, didFinishScrubbingAtTime time: CMTime, shouldResumePlayback: Bool) {
        guard let videoPlayer = self.videoPlayer else {
            owsFailDebug("video player was unexpectedly nil")
            return
        }

        videoPlayer.seek(to: time)
        if (shouldResumePlayback) {
            videoPlayer.play()
        }
    }

    // MARK: - Helpers

    var isZoomable: Bool {
        return attachment.isImage || attachment.isVideo
    }

    func zoomOut(animated: Bool) {
        if self.scrollView.zoomScale != self.scrollView.minimumZoomScale {
            self.scrollView.setZoomScale(self.scrollView.minimumZoomScale, animated: animated)
        }
    }

    // When the keyboard is popped, it can obscure the attachment view.
    // so we sometimes allow resizing the attachment.
    var shouldAllowAttachmentViewResizing: Bool = true

    var attachmentViewScale: AttachmentViewScale = .fullsize
    fileprivate func setAttachmentViewScale(_ attachmentViewScale: AttachmentViewScale, animated: Bool) {
        self.attachmentViewScale = attachmentViewScale
        ensureAttachmentViewScale(animated: animated)
    }

    func ensureAttachmentViewScale(animated: Bool) {
        let animationDuration = animated ? 0.2 : 0
        guard shouldAllowAttachmentViewResizing else {
            if self.contentContainer.transform != CGAffineTransform.identity {
                UIView.animate(withDuration: animationDuration) {
                    self.contentContainer.transform = CGAffineTransform.identity
                }
            }
            return
        }

        switch attachmentViewScale {
        case .fullsize:
            guard self.contentContainer.transform != .identity else {
                return
            }
            UIView.animate(withDuration: animationDuration) {
                self.contentContainer.transform = CGAffineTransform.identity
            }
        case .compact:
            guard self.contentContainer.transform == .identity else {
                return
            }
            UIView.animate(withDuration: animationDuration) {
                let kScaleFactor: CGFloat = 0.7
                let scale = CGAffineTransform(scaleX: kScaleFactor, y: kScaleFactor)

                let originalHeight = self.scrollView.bounds.size.height

                // Position the new scaled item to be centered with respect
                // to it's new size.
                let heightDelta = originalHeight * (1 - kScaleFactor)
                let translate = CGAffineTransform(translationX: 0, y: -heightDelta / 2)

                self.contentContainer.transform = scale.concatenating(translate)
            }
        }
    }
}

extension AttachmentPrepViewController: CaptionViewDelegate {
    func captionView(_ captionView: CaptionView, didChangeCaptionText captionText: String?, attachmentItem: SignalAttachmentItem) {
        let attachment = attachmentItem.attachment
        attachment.captionText = captionText
        prepDelegate?.prepViewController(self, didUpdateCaptionForAttachmentItem: attachmentItem)
    }

    func captionViewDidBeginEditing(_ captionView: CaptionView) {
        // Don't allow user to pan until they've dismissed the keyboard.
        // This avoids a really ugly animation from  simultaneously dismissing the keyboard
        // while loading a new PrepViewController, and it's CaptionView, whose layout depends
        // on the keyboard's position.
        self.touchInterceptorView.isHidden = false
        self.prepDelegate?.prepViewController(self, didBeginEditingCaptionView: captionView)
    }

    func captionViewDidEndEditing(_ captionView: CaptionView) {
        self.touchInterceptorView.isHidden = true
        self.prepDelegate?.prepViewController(self, didEndEditingCaptionView: captionView)
    }
}

extension AttachmentPrepViewController: UIScrollViewDelegate {

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        if isZoomable {
            return mediaMessageView
        } else {
            // don't zoom for audio or generic attachments.
            return nil
        }
    }

    fileprivate func updateMinZoomScaleForSize(_ size: CGSize) {
        Logger.debug("")

        // Ensure bounds have been computed
        mediaMessageView.layoutIfNeeded()
        guard mediaMessageView.bounds.width > 0, mediaMessageView.bounds.height > 0 else {
            Logger.warn("bad bounds")
            return
        }

        let widthScale = size.width / mediaMessageView.bounds.width
        let heightScale = size.height / mediaMessageView.bounds.height
        let minScale = min(widthScale, heightScale)
        scrollView.maximumZoomScale = minScale * 5.0
        scrollView.minimumZoomScale = minScale
        scrollView.zoomScale = minScale
    }

    // Keep the media view centered within the scroll view as you zoom
    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // The scroll view has zoomed, so you need to re-center the contents
        let scrollViewSize = self.scrollViewVisibleSize

        // First assume that mediaMessageView center coincides with the contents center
        // This is correct when the mediaMessageView is bigger than scrollView due to zoom
        var contentCenter = CGPoint(x: (scrollView.contentSize.width / 2), y: (scrollView.contentSize.height / 2))

        let scrollViewCenter = self.scrollViewCenter

        // if mediaMessageView is smaller than the scrollView visible size - fix the content center accordingly
        if self.scrollView.contentSize.width < scrollViewSize.width {
            contentCenter.x = scrollViewCenter.x
        }

        if self.scrollView.contentSize.height < scrollViewSize.height {
            contentCenter.y = scrollViewCenter.y
        }

        self.mediaMessageView.center = contentCenter
    }

    // return the scroll view center
    private var scrollViewCenter: CGPoint {
        let size = scrollViewVisibleSize
        return CGPoint(x: (size.width / 2), y: (size.height / 2))
    }

    // Return scrollview size without the area overlapping with tab and nav bar.
    private var scrollViewVisibleSize: CGSize {
        let contentInset = scrollView.contentInset
        let scrollViewSize = scrollView.bounds.standardized.size
        let width = scrollViewSize.width - (contentInset.left + contentInset.right)
        let height = scrollViewSize.height - (contentInset.top + contentInset.bottom)
        return CGSize(width: width, height: height)
    }
}

class BottomToolView: UIView {
    let mediaMessageTextToolbar: MediaMessageTextToolbar
    let galleryRailView: GalleryRailView

    let kGalleryRailViewHeight: CGFloat = 72

    required init(isAddMoreVisible: Bool) {
        mediaMessageTextToolbar = MediaMessageTextToolbar(isAddMoreVisible: isAddMoreVisible)

        galleryRailView = GalleryRailView()
        galleryRailView.scrollFocusMode = .keepWithinBounds
        galleryRailView.autoSetDimension(.height, toSize: kGalleryRailViewHeight)

        super.init(frame: .zero)

        // Specifying autorsizing mask and an intrinsic content size allows proper
        // sizing when used as an input accessory view.
        self.autoresizingMask = .flexibleHeight
        self.translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        preservesSuperviewLayoutMargins = true

        let stackView = UIStackView(arrangedSubviews: [self.galleryRailView, self.mediaMessageTextToolbar])
        stackView.axis = .vertical

        addSubview(stackView)
        stackView.autoPinEdgesToSuperviewEdges()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 

    override var intrinsicContentSize: CGSize {
        get {
            // Since we have `self.autoresizingMask = UIViewAutoresizingFlexibleHeight`, we must specify
            // an intrinsicContentSize. Specifying CGSize.zero causes the height to be determined by autolayout.
            return CGSize.zero
        }
    }
}

protocol CaptionViewDelegate: class {
    func captionView(_ captionView: CaptionView, didChangeCaptionText captionText: String?, attachmentItem: SignalAttachmentItem)
    func captionViewDidBeginEditing(_ captionView: CaptionView)
    func captionViewDidEndEditing(_ captionView: CaptionView)
}

class CaptionView: UIView {

    var captionText: String? {
        get { return textView.text }
        set {
            textView.text = newValue
            updatePlaceholderTextViewVisibility()
        }
    }

    let attachmentItem: SignalAttachmentItem
    var attachment: SignalAttachment {
        return attachmentItem.attachment
    }

    weak var delegate: CaptionViewDelegate?

    private let kMinTextViewHeight: CGFloat = 38
    private var textViewHeightConstraint: NSLayoutConstraint!

    private lazy var lengthLimitLabel: UILabel = {
        let lengthLimitLabel = UILabel()

        // Length Limit Label shown when the user inputs too long of a message
        lengthLimitLabel.textColor = .white
        lengthLimitLabel.text = NSLocalizedString("ATTACHMENT_APPROVAL_CAPTION_LENGTH_LIMIT_REACHED", comment: "One-line label indicating the user can add no more text to the attachment caption.")
        lengthLimitLabel.textAlignment = .center

        // Add shadow in case overlayed on white content
        lengthLimitLabel.layer.shadowColor = UIColor.black.cgColor
        lengthLimitLabel.layer.shadowOffset = CGSize(width: 0.0, height: 0.0)
        lengthLimitLabel.layer.shadowOpacity = 0.8
        lengthLimitLabel.isHidden = true

        return lengthLimitLabel
    }()

    // MARK: Initializers

    init(attachmentItem: SignalAttachmentItem) {
        self.attachmentItem = attachmentItem

        super.init(frame: .zero)

        backgroundColor = UIColor.black.withAlphaComponent(0.6)

        self.captionText = attachmentItem.captionText
        textView.delegate = self

        let textContainer = UIView()
        textContainer.addSubview(placeholderTextView)
        placeholderTextView.autoPinEdgesToSuperviewEdges()

        textContainer.addSubview(textView)
        textView.autoPinEdgesToSuperviewEdges()
        textViewHeightConstraint = textView.autoSetDimension(.height, toSize: kMinTextViewHeight)

        let hStack = UIStackView(arrangedSubviews: [addCaptionButton, textContainer, doneButton])
        doneButton.isHidden = true

        addSubview(hStack)
        hStack.autoPinEdgesToSuperviewMargins()

        addSubview(lengthLimitLabel)
        lengthLimitLabel.autoPinEdge(toSuperviewMargin: .left)
        lengthLimitLabel.autoPinEdge(toSuperviewMargin: .right)
        lengthLimitLabel.autoPinEdge(.bottom, to: .top, of: textView, withOffset: -9)
        lengthLimitLabel.setContentHuggingHigh()
        lengthLimitLabel.setCompressionResistanceHigh()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 

    func endEditing() {
        textView.resignFirstResponder()
    }

    override var inputAccessoryView: UIView? {
        // Don't inherit the vc's inputAccessoryView
        return nil
    }

    // MARK: Subviews

    func updatePlaceholderTextViewVisibility() {
        let isHidden: Bool = {
            guard !self.textView.isFirstResponder else {
                return true
            }

            guard let captionText = self.textView.text else {
                return false
            }

            guard captionText.count > 0 else {
                return false
            }

            return true
        }()

        placeholderTextView.isHidden = isHidden
    }

    private lazy var placeholderTextView: UITextView = {
        let placeholderTextView = UITextView()
        placeholderTextView.text = NSLocalizedString("ATTACHMENT_APPROVAL_CAPTION_PLACEHOLDER", comment: "placeholder text for an empty captioning field")
        placeholderTextView.isEditable = false

        placeholderTextView.backgroundColor = .clear
        placeholderTextView.keyboardAppearance = Theme.keyboardAppearance
        placeholderTextView.font = UIFont.ows_dynamicTypeBody

        placeholderTextView.textColor = Theme.darkThemePrimaryColor
        placeholderTextView.tintColor = Theme.darkThemePrimaryColor
        placeholderTextView.returnKeyType = .done

        return placeholderTextView
    }()

    private lazy var textView: UITextView = {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.keyboardAppearance = Theme.keyboardAppearance
        textView.font = UIFont.ows_dynamicTypeBody
        textView.textColor = Theme.darkThemePrimaryColor
        textView.tintColor = Theme.darkThemePrimaryColor

        return textView
    }()

    lazy var addCaptionButton: UIButton = {
        let addCaptionButton =  OWSButton { [weak self] in
            self?.textView.becomeFirstResponder()
        }

        let icon = #imageLiteral(resourceName: "ic_add_caption").withRenderingMode(.alwaysTemplate)
        addCaptionButton.setImage(icon, for: .normal)
        addCaptionButton.tintColor = Theme.darkThemePrimaryColor

        return addCaptionButton
    }()

    lazy var doneButton: UIButton = {
        let doneButton = OWSButton { [weak self] in
            self?.textView.resignFirstResponder()
        }
        doneButton.setTitle(CommonStrings.doneButton, for: .normal)
        doneButton.tintColor = Theme.darkThemePrimaryColor

        return doneButton
    }()
}

let kMaxCaptionCharacterCount = 240
extension CaptionView: UITextViewDelegate {
    public func textViewDidBeginEditing(_ textView: UITextView) {
        updatePlaceholderTextViewVisibility()
        doneButton.isHidden = false
        addCaptionButton.isHidden = true

        delegate?.captionViewDidBeginEditing(self)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        updatePlaceholderTextViewVisibility()
        doneButton.isHidden = true
        addCaptionButton.isHidden = false

        delegate?.captionViewDidEndEditing(self)
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let existingText: String = textView.text ?? ""
        let proposedText: String = (existingText as NSString).replacingCharacters(in: range, with: text)

        let kMaxCaptionByteCount = kOversizeTextMessageSizeThreshold / 4
        guard proposedText.utf8.count <= kMaxCaptionByteCount else {
            Logger.debug("hit caption byte count limit")
            self.lengthLimitLabel.isHidden = false

            // `range` represents the section of the existing text we will replace. We can re-use that space.
            // Range is in units of NSStrings's standard UTF-16 characters. Since some of those chars could be
            // represented as single bytes in utf-8, while others may be 8 or more, the only way to be sure is
            // to just measure the utf8 encoded bytes of the replaced substring.
            let bytesAfterDelete: Int = (existingText as NSString).replacingCharacters(in: range, with: "").utf8.count

            // Accept as much of the input as we can
            let byteBudget: Int = Int(kOversizeTextMessageSizeThreshold) - bytesAfterDelete
            if byteBudget >= 0, let acceptableNewText = text.truncated(toByteCount: UInt(byteBudget)) {
                textView.text = (existingText as NSString).replacingCharacters(in: range, with: acceptableNewText)
            }

            return false
        }

        // After verifying the byte-length is sufficiently small, verify the character count is within bounds.
        // Normally this character count should entail *much* less byte count.
        guard proposedText.count <= kMaxCaptionCharacterCount else {
            Logger.debug("hit caption character count limit")

            self.lengthLimitLabel.isHidden = false

            // `range` represents the section of the existing text we will replace. We can re-use that space.
            let charsAfterDelete: Int = (existingText as NSString).replacingCharacters(in: range, with: "").count

            // Accept as much of the input as we can
            let charBudget: Int = Int(kMaxCaptionCharacterCount) - charsAfterDelete
            if charBudget >= 0 {
                let acceptableNewText = String(text.prefix(charBudget))
                textView.text = (existingText as NSString).replacingCharacters(in: range, with: acceptableNewText)
            }

            return false
        }

        self.lengthLimitLabel.isHidden = true
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        self.delegate?.captionView(self, didChangeCaptionText: textView.text, attachmentItem: attachmentItem)
    }
}

protocol MediaMessageTextToolbarDelegate: class {
    func mediaMessageTextToolbarDidTapSend(_ mediaMessageTextToolbar: MediaMessageTextToolbar)
    func mediaMessageTextToolbarDidBeginEditing(_ mediaMessageTextToolbar: MediaMessageTextToolbar)
    func mediaMessageTextToolbarDidEndEditing(_ mediaMessageTextToolbar: MediaMessageTextToolbar)
    func mediaMessageTextToolbarDidAddMore(_ mediaMessageTextToolbar: MediaMessageTextToolbar)
}

class MediaMessageTextToolbar: UIView, UITextViewDelegate {

    weak var mediaMessageTextToolbarDelegate: MediaMessageTextToolbarDelegate?
    private let addMoreButton: UIButton
    private let sendButton: UIButton
    let textView: UITextView

    var messageText: String? {
        get { return self.textView.text }
        set { self.textView.text = newValue }
    }

    private lazy var lengthLimitLabel: UILabel = {
        let lengthLimitLabel = UILabel()

        // Length Limit Label shown when the user inputs too long of a message
        lengthLimitLabel.textColor = .white
        lengthLimitLabel.text = NSLocalizedString("ATTACHMENT_APPROVAL_MESSAGE_LENGTH_LIMIT_REACHED", comment: "One-line label indicating the user can add no more text to the media message field.")
        lengthLimitLabel.textAlignment = .center

        // Add shadow in case overlayed on white content
        lengthLimitLabel.layer.shadowColor = UIColor.black.cgColor
        lengthLimitLabel.layer.shadowOffset = CGSize(width: 0.0, height: 0.0)
        lengthLimitLabel.layer.shadowOpacity = 0.8
        lengthLimitLabel.isHidden = true

        return lengthLimitLabel
    }()

    // Layout Constants

    let kMinTextViewHeight: CGFloat = 38
    var maxTextViewHeight: CGFloat {
        // About ~4 lines in portrait and ~3 lines in landscape.
        // Otherwise we risk obscuring too much of the content.
        return UIDevice.current.orientation.isPortrait ? 160 : 100
    }
    var textViewHeightConstraint: NSLayoutConstraint!
    var textViewHeight: CGFloat

    class MessageTextView: UITextView {
        // When creating new lines, contentOffset is animated, but because because
        // we are simultaneously resizing the text view, this can cause the
        // text in the textview to be "too high" in the text view.
        // Solution is to disable animation for setting content offset.
        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            super.setContentOffset(contentOffset, animated: false)
        }
    }

    override var intrinsicContentSize: CGSize {
        get {
            // Since we have `self.autoresizingMask = UIViewAutoresizingFlexibleHeight`, we must specify
            // an intrinsicContentSize. Specifying CGSize.zero causes the height to be determined by autolayout.
            return CGSize.zero
        }
    }

    // MARK: - Initializers

    init(isAddMoreVisible: Bool) {
        self.addMoreButton = UIButton(type: .custom)
        self.sendButton = UIButton(type: .system)
        self.textView = MessageTextView()
        self.textViewHeight = kMinTextViewHeight

        super.init(frame: CGRect.zero)

        // Specifying autorsizing mask and an intrinsic content size allows proper
        // sizing when used as an input accessory view.
        self.autoresizingMask = .flexibleHeight
        self.translatesAutoresizingMaskIntoConstraints = false
        self.backgroundColor = UIColor.clear

        textView.delegate = self
        textView.keyboardAppearance = Theme.keyboardAppearance
        textView.backgroundColor = Theme.darkThemeBackgroundColor
        textView.tintColor = Theme.darkThemePrimaryColor
        textView.layer.borderColor = Theme.darkThemePrimaryColor.cgColor
        textView.layer.borderWidth = 0.5
        textView.layer.cornerRadius = kMinTextViewHeight / 2

        textView.font = UIFont.ows_dynamicTypeBody
        textView.textColor = Theme.darkThemePrimaryColor
        textView.returnKeyType = .done
        textView.textContainerInset = UIEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        textView.scrollIndicatorInsets = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 3)

        let addMoreIcon = #imageLiteral(resourceName: "album_add_more").withRenderingMode(.alwaysTemplate)
        addMoreButton.setImage(addMoreIcon, for: .normal)
        addMoreButton.tintColor = Theme.darkThemePrimaryColor
        addMoreButton.addTarget(self, action: #selector(didTapAddMore), for: .touchUpInside)

        let sendTitle = NSLocalizedString("ATTACHMENT_APPROVAL_SEND_BUTTON", comment: "Label for 'send' button in the 'attachment approval' dialog.")
        sendButton.setTitle(sendTitle, for: .normal)
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)

        sendButton.titleLabel?.font = UIFont.ows_mediumFont(withSize: 16)
        sendButton.titleLabel?.textAlignment = .center
        sendButton.tintColor = Theme.galleryHighlightColor

        // Increase hit area of send button
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let contentView = UIView()
        contentView.addSubview(sendButton)
        contentView.addSubview(textView)
        contentView.addSubview(lengthLimitLabel)
        if isAddMoreVisible {
            contentView.addSubview(addMoreButton)
        }

        addSubview(contentView)
        contentView.autoPinEdgesToSuperviewEdges()

        // Layout
        let kToolbarMargin: CGFloat = 8

        // We have to wrap the toolbar items in a content view because iOS (at least on iOS10.3) assigns the inputAccessoryView.layoutMargins
        // when resigning first responder (verified by auditing with `layoutMarginsDidChange`).
        // The effect of this is that if we were to assign these margins to self.layoutMargins, they'd be blown away if the
        // user dismisses the keyboard, giving the input accessory view a wonky layout.
        contentView.layoutMargins = UIEdgeInsets(top: kToolbarMargin, left: kToolbarMargin, bottom: kToolbarMargin, right: kToolbarMargin)

        self.textViewHeightConstraint = textView.autoSetDimension(.height, toSize: kMinTextViewHeight)

        // We pin all three edges explicitly rather than doing something like:
        //  textView.autoPinEdges(toSuperviewMarginsExcludingEdge: .right)
        // because that method uses `leading` / `trailing` rather than `left` vs. `right`.
        // So it doesn't work as expected with RTL layouts when we explicitly want something
        // to be on the right side for both RTL and LTR layouts, like with the send button.
        // I believe this is a bug in PureLayout. Filed here: https://github.com/PureLayout/PureLayout/issues/209
        textView.autoPinEdge(toSuperviewMargin: .top)
        textView.autoPinEdge(toSuperviewMargin: .bottom)
        if isAddMoreVisible {
            addMoreButton.autoPinEdge(toSuperviewMargin: .left)
            textView.autoPinEdge(.left, to: .right, of: addMoreButton, withOffset: kToolbarMargin)
            addMoreButton.autoAlignAxis(.horizontal, toSameAxisOf: sendButton)
            addMoreButton.setContentHuggingHigh()
            addMoreButton.setCompressionResistanceHigh()
        } else {
            textView.autoPinEdge(toSuperviewMargin: .left)
        }

        sendButton.autoPinEdge(.left, to: .right, of: textView, withOffset: kToolbarMargin)
        sendButton.autoPinEdge(.bottom, to: .bottom, of: textView, withOffset: -3)

        sendButton.autoPinEdge(toSuperviewMargin: .right)
        sendButton.setContentHuggingHigh()
        sendButton.setCompressionResistanceHigh()

        lengthLimitLabel.autoPinEdge(toSuperviewMargin: .left)
        lengthLimitLabel.autoPinEdge(toSuperviewMargin: .right)
        lengthLimitLabel.autoPinEdge(.bottom, to: .top, of: textView, withOffset: -6)
        lengthLimitLabel.setContentHuggingHigh()
        lengthLimitLabel.setCompressionResistanceHigh()
    }

    required init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    // MARK: -

    @objc func didTapSend() {
        mediaMessageTextToolbarDelegate?.mediaMessageTextToolbarDidTapSend(self)
    }

    @objc func didTapAddMore() {
        mediaMessageTextToolbarDelegate?.mediaMessageTextToolbarDidAddMore(self)
    }

    // MARK: - UITextViewDelegate

    public func textViewDidChange(_ textView: UITextView) {
        updateHeight(textView: textView)
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {

        let existingText: String = textView.text ?? ""
        let proposedText: String = (existingText as NSString).replacingCharacters(in: range, with: text)

        guard proposedText.utf8.count <= kOversizeTextMessageSizeThreshold else {
            Logger.debug("long text was truncated")
            self.lengthLimitLabel.isHidden = false

            // `range` represents the section of the existing text we will replace. We can re-use that space.
            // Range is in units of NSStrings's standard UTF-16 characters. Since some of those chars could be
            // represented as single bytes in utf-8, while others may be 8 or more, the only way to be sure is
            // to just measure the utf8 encoded bytes of the replaced substring.
            let bytesAfterDelete: Int = (existingText as NSString).replacingCharacters(in: range, with: "").utf8.count

            // Accept as much of the input as we can
            let byteBudget: Int = Int(kOversizeTextMessageSizeThreshold) - bytesAfterDelete
            if byteBudget >= 0, let acceptableNewText = text.truncated(toByteCount: UInt(byteBudget)) {
                textView.text = (existingText as NSString).replacingCharacters(in: range, with: acceptableNewText)
            }

            return false
        }
        self.lengthLimitLabel.isHidden = true

        // Though we can wrap the text, we don't want to encourage multline captions, plus a "done" button
        // allows the user to get the keyboard out of the way while in the attachment approval view.
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        } else {
            return true
        }
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        mediaMessageTextToolbarDelegate?.mediaMessageTextToolbarDidBeginEditing(self)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        mediaMessageTextToolbarDelegate?.mediaMessageTextToolbarDidEndEditing(self)
    }

    // MARK: - Helpers

    private func updateHeight(textView: UITextView) {
        // compute new height assuming width is unchanged
        let currentSize = textView.frame.size
        let newHeight = clampedTextViewHeight(fixedWidth: currentSize.width)

        if newHeight != textViewHeight {
            Logger.debug("TextView height changed: \(textViewHeight) -> \(newHeight)")
            textViewHeight = newHeight
            textViewHeightConstraint?.constant = textViewHeight
            invalidateIntrinsicContentSize()
        }
    }

    private func clampedTextViewHeight(fixedWidth: CGFloat) -> CGFloat {
        let contentSize = textView.sizeThatFits(CGSize(width: fixedWidth, height: CGFloat.greatestFiniteMagnitude))
        return CGFloatClamp(contentSize.height, kMinTextViewHeight, maxTextViewHeight)
    }
}
