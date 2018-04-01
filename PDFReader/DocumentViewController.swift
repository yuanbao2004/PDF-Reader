//
//  DocumentViewController.swift
//  PDFReader
//
//  Created by Eru on H29/09/28.
//  Copyright © 平成29年 Hacking Gate. All rights reserved.
//

import UIKit
import PDFKit
import CoreData
import CloudKit

protocol SettingsDelegate {
    var isHorizontalScroll: Bool { get set }
    var isRightToLeft: Bool { get set }
    var isEncrypted: Bool { get }
    var allowsDocumentAssembly: Bool { get }
    var prefersTwoUpInLandscapeForPad: Bool { get }
    var displayMode: PDFDisplayMode { get }
    func updateScrollDirection() -> Void
    func goToPage(page: PDFPage) -> Void
    func selectOutline(outline: PDFOutline) -> Void
    func setPreferredDisplayMode(_ twoUpInLandscapeForPad: Bool) -> Void
}

extension DocumentViewController: SettingsDelegate {
    var allowsDocumentAssembly: Bool {
        get {
            if let document = pdfView.document {
                return document.allowsDocumentAssembly
            } else {
                return false
            }
        }
    }
    
    var displayMode: PDFDisplayMode {
        get {
            return pdfView.displayMode
        }
    }
    
    func goToPage(page: PDFPage) {
        pdfView.go(to: page)
    }
    
    func selectOutline(outline: PDFOutline) {
        if let action = outline.action as? PDFActionGoTo {
            pdfView.go(to: action.destination)
        }
    }
}

class DocumentViewController: UIViewController {
    
    @IBOutlet weak var pdfView: PDFView!
    @IBOutlet weak var blurEffectView: UIVisualEffectView!
    @IBOutlet weak var pageLabel: UILabel!
    var blurDismissTimer = Timer()
    
    var document: Document?
    
    // data
    var managedObjectContext: NSManagedObjectContext? = nil
    var pageIndex: Int64 = 0
    var currentEntity: DocumentEntity? = nil
    var currentCKRecords: [CKRecord]? {
        didSet {
            if didMoveToLastViewedPage {
                checkForNewerRecords()
            }
        }
    }
    var didMoveToLastViewedPage = false
    
    // scaleFactor
    struct ScaleFactor {
        // store factor for single mode
        var portrait: CGFloat
        var landscape: CGFloat
        // devide by 2 for two up mode
    }
    // different form pdfView.scaleFactorForSizeToFit, the scaleFactorForSizeToFit use superArea not safeArea
    var scaleFactorForSizeToFit: ScaleFactor?
    var scaleFactorVertical: ScaleFactor?
    var scaleFactorHorizontal: ScaleFactor?
    var zoomedIn = false
    
    // offset
    var offsetPortrait: CGPoint?
    var offsetLandscape: CGPoint?
    
    // delegate properties
    var isHorizontalScroll = false
    var isRightToLeft = false
    var isEncrypted = false
    var isPageExchangedForRTL = false // if allowsDocumentAssembly is false, then the value should always be false
    var prefersTwoUpInLandscapeForPad = false // default value
    
    override func viewWillAppear(_ animated: Bool) {
        updateInterface()
        super.viewWillAppear(animated)
        navigationController?.hidesBarsOnTap = true
        
        if (pdfView.document != nil) { return }
        
        // Access the document
        document?.open(completionHandler: { (success) in
            if success {
                // Display the content of the document, e.g.:
                self.navigationItem.title = self.document?.localizedName
                
                guard let pdfURL: URL = (self.document?.fileURL) else { return }
                guard let document = PDFDocument(url: pdfURL) else { return }
                
                self.isEncrypted = document.isEncrypted
                
                self.pdfView.document = document
                
                self.moveToLastViewedPage()
                self.getScaleFactorForSizeToFitAndOffset()
                self.setMinScaleFactorForSizeToFit()
                self.setScaleFactorForUser()
                
                if let documentEntity = self.currentEntity {
                    self.isHorizontalScroll = documentEntity.isHorizontalScroll
                    self.isRightToLeft = documentEntity.isRightToLeft
                    self.updateScrollDirection()
                }
                self.moveToLastViewedOffset()

                self.setPDFThumbnailView()
                
                self.checkForNewerRecords()
            } else {
                // Make sure to handle the failed import appropriately, e.g., by presenting an error message to the user.
            }
        })
    }
    
    override func viewDidLoad() {
        enableCustomMenus()
        blurEffectView.layer.masksToBounds = true
        blurEffectView.layer.cornerRadius = 6
        
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(doubleTapGestureRecognizerHandler(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        pdfView.addGestureRecognizer(doubleTapGesture)
        navigationController?.barHideOnTapGestureRecognizer.require(toFail: doubleTapGesture)
        navigationController?.barHideOnTapGestureRecognizer.addTarget(self, action: #selector(barHideOnTapGestureRecognizerHandler))
        
        
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.displayBox = .cropBox
        if let documentEntity = self.currentEntity {
            prefersTwoUpInLandscapeForPad = documentEntity.prefersTwoUpInLandscapeForPad
        }
        if prefersTwoUpInLandscapeForPad && UIDevice.current.userInterfaceIdiom == .pad && UIApplication.shared.statusBarOrientation.isLandscape {
            pdfView.displayMode = .twoUpContinuous
        } else {
            pdfView.displayMode = .singlePageContinuous
        }

        pdfView.scrollView?.scrollsToTop = false
        pdfView.scrollView?.contentInsetAdjustmentBehavior = .scrollableAxes
        
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(updateInterface),
                           name: .UIApplicationWillEnterForeground,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(saveAndClose),
                           name: .UIApplicationDidEnterBackground,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(willChangeOrientationHandler),
                           name: .UIApplicationWillChangeStatusBarOrientation,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(didChangeOrientationHandler),
                           name: .UIApplicationDidChangeStatusBarOrientation,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(didChangePageHandler),
                           name: .PDFViewPageChanged,
                           object: nil)
    }
    
    @objc func updateInterface() {
        if presentingViewController != nil {
            // use same UI style as DocumentBrowserViewController
            view.backgroundColor = presentingViewController?.view.backgroundColor
            view.tintColor = presentingViewController?.view.tintColor
            navigationController?.navigationBar.tintColor = presentingViewController?.view.tintColor
            if UserDefaults.standard.integer(forKey: (presentingViewController as! DocumentBrowserViewController).browserUserInterfaceStyleKey) == UIDocumentBrowserViewController.BrowserUserInterfaceStyle.dark.rawValue {
                navigationController?.navigationBar.barStyle = .black
                navigationController?.toolbar.barStyle = .black
                // use true black background to protect OLED screen
                view.backgroundColor = .black
            } else {
                navigationController?.navigationBar.barStyle = .default
                navigationController?.toolbar.barStyle = .default
            }
        }
    }
    
    func setPreferredDisplayMode(_ twoUpInLandscapeForPad: Bool) {
        prefersTwoUpInLandscapeForPad = twoUpInLandscapeForPad
        if let page = pdfView.currentPage {
            if twoUpInLandscapeForPad && UIDevice.current.userInterfaceIdiom == .pad && UIApplication.shared.statusBarOrientation.isLandscape {
                pdfView.displayMode = .twoUpContinuous
            } else {
                pdfView.displayMode = .singlePageContinuous
            }
            setMinScaleFactorForSizeToFit()
            pdfView.go(to: page) // workaround to fix
            setScaleFactorForUser()
        }

    }
    
    func updateScrollDirection() {
        updateUserScaleFactorAndOffset(changeOrientation: false)
        
        // experimental feature
        if let currentPage = pdfView.currentPage {
            if pdfView.displayMode == .singlePageContinuous && allowsDocumentAssembly {
                if isRightToLeft != isPageExchangedForRTL {
                    if pdfView.displaysRTL {
                        pdfView.displaysRTL = false
                    }
                    exchangePageForRTL(isRightToLeft)
                }
                if isRightToLeft {
                    // single page RTL use horizontal scroll
                    if isRightToLeft {
                        isHorizontalScroll = true
                    }
                }
            } else if pdfView.displayMode == .twoUpContinuous {
                if isRightToLeft != pdfView.displaysRTL  {
                    if isPageExchangedForRTL {
                        exchangePageForRTL(false)
                    }
                    pdfView.displaysRTL = isRightToLeft
                }
                if isRightToLeft {
                    // two up RTL use vertical scroll
                    if isRightToLeft {
                        isHorizontalScroll = false
                    }
                }
            }
            
            if isHorizontalScroll != (pdfView.displayDirection == .horizontal) {
                if isHorizontalScroll {
                    pdfView.displayDirection = .horizontal
                } else {
                    if isPageExchangedForRTL {
                        exchangePageForRTL(false)
                    }
                    pdfView.displayDirection = .vertical
                }
                pdfView.scrollView?.showsHorizontalScrollIndicator = pdfView.displayDirection == .horizontal
                pdfView.scrollView?.showsVerticalScrollIndicator = pdfView.displayDirection == .vertical
            }
            
            pdfView.layoutDocumentView()
            pdfView.go(to: currentPage)
        }
        
        setMinScaleFactorForSizeToFit()
        setScaleFactorForUser()
    }
    
    func exchangePageForRTL(_ exchange: Bool) {
        if exchange != isPageExchangedForRTL, let currentPage = pdfView.currentPage, let document: PDFDocument = pdfView.document {
            let currentIndex: Int = document.index(for: currentPage)
            print("currentIndex: \(currentIndex)")
            
            // ページ交換ファンクションを利用して、降順ソートして置き換える。
            let pageCount: Int = document.pageCount
            
            print("pageCount: \(pageCount)")
            for i in 0..<pageCount/2 {
                print("exchangePage at: \(i), withPageAt: \(pageCount-i-1)")
                document.exchangePage(at: i, withPageAt: pageCount-i-1)
            }
            if currentIndex != pageCount - currentIndex - 1 {
                if let pdfPage = document.page(at: pageCount - currentIndex - 1) {
                    print("go to: \(pageCount - currentIndex - 1)")
                    pdfView.go(to: pdfPage)
                }
            }
        }
        
        isPageExchangedForRTL = exchange
    }
    
    func setPDFThumbnailView() {
        if let margins = navigationController?.toolbar.safeAreaLayoutGuide {
            let pdfThumbnailView = PDFThumbnailView.init()
            pdfThumbnailView.pdfView = pdfView
            pdfThumbnailView.layoutMode = .horizontal
            pdfThumbnailView.translatesAutoresizingMaskIntoConstraints = false
            navigationController?.toolbar.addSubview(pdfThumbnailView)
            pdfThumbnailView.leadingAnchor.constraint(equalTo: margins.leadingAnchor).isActive = true
            pdfThumbnailView.trailingAnchor.constraint(equalTo: margins.trailingAnchor).isActive = true
            pdfThumbnailView.topAnchor.constraint(equalTo: margins.topAnchor).isActive = true
            pdfThumbnailView.bottomAnchor.constraint(equalTo: margins.bottomAnchor).isActive = true
        }
    }
    
    override var prefersStatusBarHidden: Bool {
        return navigationController?.isNavigationBarHidden == true || super.prefersStatusBarHidden
    }
    
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }
    
    override func prefersHomeIndicatorAutoHidden() -> Bool {
        return navigationController?.isToolbarHidden == true
    }
    
    @objc func doubleTapGestureRecognizerHandler(_ sender: UITapGestureRecognizer) {
        print(sender.location(in: pdfView))
        
        if pdfView.scaleFactor == pdfView.maxScaleFactor {
            zoomedIn = true
        }
        if !zoomedIn {
            updateUserScaleFactorAndOffset(changeOrientation: false)
        }
        var scaleFactor: CGFloat?
        if let scaleFactorVertical = scaleFactorVertical, let scaleFactorHorizontal = scaleFactorHorizontal {
            if UIApplication.shared.statusBarOrientation.isPortrait {
                if pdfView.displayDirection == .vertical, pdfView.scaleFactor != scaleFactorVertical.portrait {
                    scaleFactor = scaleFactorVertical.portrait
                } else if pdfView.displayDirection == .horizontal, pdfView.scaleFactor != scaleFactorHorizontal.portrait {
                    scaleFactor = scaleFactorHorizontal.portrait
                }
            } else if UIApplication.shared.statusBarOrientation.isLandscape {
                if pdfView.displayDirection == .vertical, pdfView.scaleFactor != scaleFactorVertical.landscape {
                    scaleFactor = scaleFactorVertical.landscape
                } else if pdfView.displayDirection == .horizontal, pdfView.scaleFactor != scaleFactorHorizontal.landscape {
                    scaleFactor = scaleFactorHorizontal.landscape
                }
            }
        }
        if let scaleFactor = scaleFactor {
            // zoom out
            pdfView.scrollView?.setZoomScale(scaleFactor, animated: true)
            zoomedIn = false
            return
        }
        
        if let page = pdfView.page(for: sender.location(in: pdfView), nearest: false) {
            // tap point in page space
            let pagePoint = pdfView.convert(sender.location(in: pdfView), to: page)
            if let scrollView = pdfView.scrollView {
                
                // normal zoom in
                let locationInView = sender.location(in: pdfView)
                let boundsInView = CGRect(x: locationInView.x - 64, y: locationInView.y - 64, width: 128, height: 128)
                let boundsInPage = pdfView.convert(boundsInView, to: page)
                var boundsInScroll = scrollView.convert(boundsInView, from: pdfView)
                
                if let selection = page.selectionForLine(at: pagePoint), selection.pages.first == page, let string = selection.string, string.count > 1 {
                    // zoom in to fit text
                    // selection bounds in page space
                    let boundsInPage = selection.bounds(for: page)
                    // selection bounds in view space
                    let boundsInView = pdfView.convert(boundsInPage, from: page)
                    // selection bounds in scroll space
                    boundsInScroll = scrollView.convert(boundsInView, from: pdfView)
                }
                
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut], animations: {
                    let safeAreaWidth = self.pdfView.frame.width - self.pdfView.safeAreaInsets.left - self.pdfView.safeAreaInsets.right
                    let safeAreaHeight = self.pdfView.frame.height - self.pdfView.safeAreaInsets.top - self.pdfView.safeAreaInsets.bottom
                    
                    // + 10 to not overlap scroll indicator
                    let widthMultiplier = safeAreaWidth / (boundsInScroll.size.width + 20)
                    let heightMultiplier = safeAreaHeight / (boundsInScroll.size.height + 20)
                    if widthMultiplier <= heightMultiplier {
                        scrollView.setZoomScale(scrollView.zoomScale * widthMultiplier, animated: false)
                    } else {
                        scrollView.setZoomScale(scrollView.zoomScale * heightMultiplier, animated: false)
                    }
                    
                    // recalculate
                    if let selection = page.selectionForLine(at: pagePoint), selection.pages.first == page, let string = selection.string, string.count > 1 {
                        // zoom in to fit text
                        // selection bounds in page space
                        let boundsInPage = selection.bounds(for: page)
                        // selection bounds in view space
                        let boundsInView = self.pdfView.convert(boundsInPage, from: page)
                        // selection bounds in scroll space
                        boundsInScroll = scrollView.convert(boundsInView, from: self.pdfView)
                    } else {
                        // normal zoom in
                        // location bounds in view space
                        let boundsInView = self.pdfView.convert(boundsInPage, from: page)
                        // location bounds in scroll space
                        boundsInScroll = scrollView.convert(boundsInView, from: self.pdfView)
                    }
                    
                    // if navigation bar or tool bar is not hidden
                    let diffYToFix = (self.pdfView.safeAreaInsets.top - self.pdfView.safeAreaInsets.bottom) / 2
                    
                    let offset = CGPoint(x: boundsInScroll.midX - self.pdfView.center.x, y: boundsInScroll.midY - self.pdfView.frame.height / 2 - diffYToFix)
                    scrollView.setContentOffset(offset, animated: false)
                }, completion: { (successful) in
                    self.zoomedIn = successful
                })
                
            }
        }
    }
    
    @objc func barHideOnTapGestureRecognizerHandler() {
        navigationController?.setToolbarHidden(navigationController?.isNavigationBarHidden == true, animated: true)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    
    func getScaleFactorForSizeToFitAndOffset() {
        // make sure to init
        if let verticalPortrait = currentEntity?.scaleFactorVerticalPortrait, let verticalLandscape = currentEntity?.scaleFactorVerticalLandscape {
            scaleFactorVertical = ScaleFactor(portrait: CGFloat(verticalPortrait), landscape: CGFloat(verticalLandscape))
        } else {
            scaleFactorVertical = ScaleFactor(portrait: 0.25, landscape: 0.25)
        }
        if let horizontalPortrait = currentEntity?.scaleFactorHorizontalPortrait, let horizontalLandscape = currentEntity?.scaleFactorVerticalLandscape {
            scaleFactorHorizontal = ScaleFactor(portrait: CGFloat(horizontalPortrait), landscape: CGFloat(horizontalLandscape))
        } else {
            scaleFactorHorizontal = ScaleFactor(portrait: 0.25, landscape: 0.25)
        }

        if pdfView.displayDirection == .vertical {
            let frame = view.frame
            let aspectRatio = frame.size.width / frame.size.height
            // if it is iPhoneX, the pdfView.scaleFactorForSizeToFit is already optimized for save area
            let divider = (pdfView.frame.width - pdfView.safeAreaInsets.left - pdfView.safeAreaInsets.right) / pdfView.frame.width
            // the scaleFactor defines the super area scale factor
            var scaleFactor = pdfView.scaleFactorForSizeToFit / divider
            if pdfView.displayMode == .twoUpContinuous {
                scaleFactor *= 2
            }
            if UIApplication.shared.statusBarOrientation.isPortrait {
                scaleFactorForSizeToFit = ScaleFactor(portrait: scaleFactor,
                                                      landscape: scaleFactor / aspectRatio)
            } else if UIApplication.shared.statusBarOrientation.isLandscape {
                scaleFactorForSizeToFit = ScaleFactor(portrait: scaleFactor / aspectRatio,
                                                      landscape: scaleFactor)
            }
        }
        
        // offset
        offsetPortrait = currentEntity?.offsetLandscape as? CGPoint
        offsetLandscape = currentEntity?.offsetLandscape as? CGPoint
    }
    
    // SizeToFit currentlly only works for vertical display direction
    func setMinScaleFactorForSizeToFit() {
        if pdfView.displayDirection == .vertical, let scaleFactorForSizeToFit = scaleFactorForSizeToFit {
            if UIApplication.shared.statusBarOrientation.isPortrait {
                if pdfView.displayMode == .singlePageContinuous {
                    pdfView.minScaleFactor = scaleFactorForSizeToFit.portrait
                } else if pdfView.displayMode == .twoUpContinuous {
                    pdfView.minScaleFactor = scaleFactorForSizeToFit.portrait / 2
                }
            } else if UIApplication.shared.statusBarOrientation.isLandscape {
                // set minScaleFactor to safe area for iPhone X and later
                let multiplier = (pdfView.frame.width - pdfView.safeAreaInsets.left - pdfView.safeAreaInsets.right) / pdfView.frame.width
                if pdfView.displayMode == .singlePageContinuous {
                    pdfView.minScaleFactor = scaleFactorForSizeToFit.landscape * multiplier
                } else if pdfView.displayMode == .twoUpContinuous {
                    pdfView.minScaleFactor = scaleFactorForSizeToFit.landscape / 2 * multiplier
                }
            }
        }
    }
    
    func setScaleFactorForUser() {
        var scaleFactor: ScaleFactor?
        // if user had opened this PDF before, the stored scaleFactor is already optimized for safeArea.
        if pdfView.displayDirection == .vertical {
            scaleFactor = scaleFactorVertical
        } else if pdfView.displayDirection == .horizontal {
            scaleFactor = scaleFactorHorizontal
        }
        
        if let scaleFactor = scaleFactor {
            print("set scale factor: \(scaleFactor)")
            if UIApplication.shared.statusBarOrientation.isPortrait {
                if pdfView.displayMode == .singlePageContinuous {
                    pdfView.scaleFactor = scaleFactor.portrait
                } else if pdfView.displayMode == .twoUpContinuous {
                    pdfView.scaleFactor = scaleFactor.portrait / 2
                }
            } else if UIApplication.shared.statusBarOrientation.isLandscape {
                if pdfView.displayMode == .singlePageContinuous {
                    pdfView.scaleFactor = scaleFactor.landscape
                } else if pdfView.displayMode == .twoUpContinuous {
                    pdfView.scaleFactor = scaleFactor.landscape / 2
                }
            }
        }
    }
    
    func updateUserScaleFactorAndOffset(changeOrientation: Bool) {
        // for save
        // XOR operator for bool (!=)
        if UIApplication.shared.statusBarOrientation.isPortrait != changeOrientation {
            if pdfView.displayDirection == .vertical {
                scaleFactorVertical?.portrait = pdfView.scaleFactor
            } else if pdfView.displayDirection == .horizontal {
                scaleFactorHorizontal?.portrait = pdfView.scaleFactor
            }
            
            offsetPortrait = pdfView.scrollView?.contentOffset
        } else if UIApplication.shared.statusBarOrientation.isLandscape != changeOrientation {
            if pdfView.displayDirection == .vertical {
                scaleFactorVertical?.landscape = pdfView.scaleFactor
            } else if pdfView.displayDirection == .horizontal {
                scaleFactorHorizontal?.landscape = pdfView.scaleFactor
            }
            
            offsetLandscape = pdfView.scrollView?.contentOffset
        }
    }
    
    func moveToLastViewedPage() {
        if let currentEntity = currentEntity {
            pageIndex = currentEntity.pageIndex
        } else if isHorizontalScroll {
            // 初めて読む　且つ　縦書き
            if let pageCount: Int = pdfView.document?.pageCount {
                pageIndex = Int64(pageCount - 1)
            }
        }
        // TODO: if pageIndex == pageCount - 1, then go to last CGRect
        if let pdfPage = pdfView.document?.page(at: Int(pageIndex)) {
            pdfView.go(to: pdfPage)
        }
    }
    
    func moveToLastViewedOffset() {
        if let currentPage = pdfView.currentPage, let currentOffset = pdfView.scrollView?.contentOffset {
            if UIApplication.shared.statusBarOrientation.isPortrait, let offsetPortrait = currentEntity?.offsetPortrait as? CGPoint {
                pdfView.scrollView?.contentOffset = offsetPortrait
            } else if UIApplication.shared.statusBarOrientation.isLandscape, let offsetLandscape = currentEntity?.offsetLandscape as? CGPoint {
                pdfView.scrollView?.contentOffset = offsetLandscape
            }
            if pdfView.currentPage != currentPage {
                print("in case something wrong \nOld: \(currentPage) \nNew: \(String(describing: pdfView.currentPage)) \nmove to previous offset")
                pdfView.scrollView?.contentOffset = currentOffset
            }
        }
        didMoveToLastViewedPage = true
    }
    
    // call after moveToLastViewedPage()
    func checkForNewerRecords() {
        if let record = currentCKRecords?.first, let modificationDate = record["modificationDate"] as? Date, let cloudPageIndex = record["pageIndex"] as? NSNumber {
            if let currentModificationDate = currentEntity?.modificationDate {
                if currentModificationDate > modificationDate { return }
            }
            if cloudPageIndex.int64Value != pageIndex {
                var message = modificationDate.description(with: Locale.current)
                if let modifiedByDevice = record["modifiedByDevice"] as? String {
                    message += "\n\(NSLocalizedString("Device:", comment: "")) \(modifiedByDevice)"
                }
                message += "\n\(NSLocalizedString("Last Viewed Page:", comment: "")) \(cloudPageIndex)"
                
                let alertController: UIAlertController = UIAlertController(title: NSLocalizedString("Found iCloud Data", comment: ""), message: message, preferredStyle: .alert)
                
                alertController.view.tintColor = view.tintColor
                
                let defaultAction: UIAlertAction = UIAlertAction(title: NSLocalizedString("Move", comment: ""), style: .default, handler: { (action: UIAlertAction?) in
                    self.pageIndex = cloudPageIndex.int64Value
                    if let pdfPage = self.pdfView.document?.page(at: Int(self.pageIndex)) {
                        self.pdfView.go(to: pdfPage)
                    }
                })
                
                let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: UIAlertActionStyle.cancel, handler: nil)
                
                alertController.addAction(cancelAction)
                alertController.addAction(defaultAction)
                
                // fix crash 'NSInternalInconsistencyException', reason: 'accessing _cachedSystemAnimationFence requires the main thread'
                DispatchQueue.main.async {
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }
    
    @objc func willChangeOrientationHandler() {
        updateUserScaleFactorAndOffset(changeOrientation: true)
    }
    
    @objc func didChangeOrientationHandler() {
        // detect if user enabled and update scale factor
        setPreferredDisplayMode(prefersTwoUpInLandscapeForPad)
        updateScrollDirection()
    }
    
    @objc func didChangePageHandler() {
        guard let pdfDocument = pdfView.document else { return }
        guard let currentPage = pdfView.currentPage else { return }
        let currentIndex = pdfDocument.index(for: currentPage)
        // currentIndex starts from 0
        pageLabel.text = "\(currentIndex+1) / \(pdfDocument.pageCount)"
        
        blurEffectView.alpha = 1.0
        blurEffectView.isHidden = false
        blurDismissTimer.invalidate()
        blurDismissTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(hidePageLabel), userInfo: nil, repeats: false)
    }
    
    @objc func hidePageLabel() {
        UIView.animate(withDuration: 0.5, delay: 0.0, options: [.curveEaseOut], animations: {
            self.blurEffectView.alpha = 0.0
        }) { (completed) in
            self.blurEffectView.isHidden = true
        }
    }
    
    @IBAction func shareAction() {
        let activityVC = UIActivityViewController(activityItems: [document?.fileURL as Any], applicationActivities: nil)
        self.present(activityVC, animated: true, completion: nil)
    }
    
    @IBAction func dismissDocumentViewController() {
        dismiss(animated: true) {
            self.saveAndClose()
        }
    }
    
    @objc func saveAndClose() {
        guard let pdfDocument = pdfView.document else { return }
        if let currentPage = pdfView.currentPage {
            var currentIndex = pdfDocument.index(for: currentPage)
            if isRightToLeft {
                currentIndex = pdfDocument.pageCount - currentIndex - 1
            }
            if let documentEntity = currentEntity {
                if let record = currentCKRecords?.first {
                    // if another device have the same bookmark but different recordID
                    documentEntity.uuid = UUID(uuidString: record.recordID.recordName)
                }
                documentEntity.pageIndex = Int64(currentIndex)
                update(entity: documentEntity)
                
                print("updating entity: \(documentEntity)")
                if let context = self.managedObjectContext {
                    self.saveContext(context)
                }
            } else {
                do {
                    if let bookmark = try document?.fileURL.bookmarkData() {
                        self.insertNewObject(bookmark, pageIndex: Int64(currentIndex))
                    }
                } catch let error as NSError {
                    print("Set Bookmark Fails: \(error.description)")
                }
            }
        }
        
        self.document?.close(completionHandler: nil)
    }
    
    // MARK: - Save Data
    
    @objc
    func insertNewObject(_ bookmark: Data, pageIndex: Int64) {
        if let context = self.managedObjectContext {
            let newDocument = DocumentEntity(context: context)
            
            if let record = currentCKRecords?.first {
                // if the record exists in iCloud but not in CoreData
                newDocument.uuid = UUID(uuidString: record.recordID.recordName)
            } else {
                newDocument.uuid = UUID()
            }
            newDocument.creationDate = Date()
            newDocument.bookmarkData = bookmark
            newDocument.pageIndex = pageIndex
            update(entity: newDocument)
            
            print("saving: \(newDocument)")
            
            self.saveContext(context)
        } else {
            print("context not exist")
        }
    }

    func update(entity: DocumentEntity) {
        entity.modificationDate = Date()
        entity.isHorizontalScroll = self.isHorizontalScroll
        entity.isRightToLeft = self.isRightToLeft
        entity.prefersTwoUpInLandscapeForPad = self.prefersTwoUpInLandscapeForPad
        
        // store user scale factor
        updateUserScaleFactorAndOffset(changeOrientation: false)
        if let scaleFactorVertical = scaleFactorVertical {
            entity.scaleFactorVerticalPortrait = Float(scaleFactorVertical.portrait)
            entity.scaleFactorVerticalLandscape = Float(scaleFactorVertical.landscape)
        }
        if let scaleFactorHorizontal = scaleFactorHorizontal {
            entity.scaleFactorHorizontalPortrait = Float(scaleFactorHorizontal.portrait)
            entity.scaleFactorHorizontalLandscape = Float(scaleFactorHorizontal.landscape)
        }
        
        if let offsetPortrait = offsetPortrait {
            entity.offsetPortrait = offsetPortrait as NSObject
        }
        if let offsetLandscape = offsetLandscape {
            entity.offsetLandscape = offsetLandscape as NSObject
        }
        
    }
    
    func saveContext(_ context: NSManagedObjectContext) {
        // Save the context.
        do {
            try context.save()
        } catch {
            // Replace this implementation with code to handle the error appropriately.
            // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            let nserror = error as NSError
            fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
        }
    }
    
}

extension DocumentViewController {
    // MARK: - Custom Menus
    
    func enableCustomMenus() {
        let define = UIMenuItem(title: NSLocalizedString("Define", comment: "define"), action: #selector(define(_:)))
        UIMenuController.shared.menuItems = [define]
    }
    
    @objc func define(_ sender: UIMenuController) {
        if let term = pdfView.currentSelection?.string {
            let referenceLibraryVC = UIReferenceLibraryViewController(term: term)
            self.present(referenceLibraryVC, animated: true, completion: nil)
        }
    }
}

extension DocumentViewController: UIPopoverPresentationControllerDelegate {
    // MARK: - PopoverTableViewController Presentation

    // iOS Popover presentation Segue
    // http://sunnycyk.com/2015/08/ios-popover-presentation-segue/
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if (segue.identifier == "PopoverSettings") {
            if let popopverVC: PopoverTableViewController = segue.destination as? PopoverTableViewController {
                popopverVC.modalPresentationStyle = .popover
                popopverVC.popoverPresentationController?.delegate = self
                popopverVC.delegate = self
                let width = popopverVC.preferredContentSize.width
                var height = popopverVC.preferredContentSize.height
                if !isEncrypted {
                    // 289 - 44 = 245
                    height -= 44
                }
                if UIDevice.current.userInterfaceIdiom != .pad {
                    height -= 44
                }
                
                popopverVC.preferredContentSize = CGSize(width: width, height: height)

            }
        } else if (segue.identifier == "Container") {
            if let containerVC: ContainerViewController = segue.destination as? ContainerViewController {
                containerVC.pdfDocument = pdfView.document
                containerVC.displayBox = pdfView.displayBox
                if let currentPage = pdfView.currentPage, let document: PDFDocument = pdfView.document {
                    containerVC.currentIndex = document.index(for: currentPage)
                }
                containerVC.delegate = self
            }
        }
    }
    
    // fix for iPhone Plus
    // https://stackoverflow.com/q/36349303/4063462
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }
    
}

extension PDFView {
    var scrollView: UIScrollView? {
        for view in self.subviews {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
        }
        return nil
    }
}
