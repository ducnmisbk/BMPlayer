//
//  BMPlayerLayerView.swift
//  Pods
//
//  Created by BrikerMan on 16/4/28.
//  Edited by Ducnmisbk on 20/3/2.
//
//

import AVFoundation
import AVKit
import Foundation
import UIKit

/**
 Player status emun

 - notSetURL:      not set url yet
 - readyToPlay:    player ready to play
 - buffering:      player buffering
 - bufferFinished: buffer finished
 - playedToTheEnd: played to the End
 - error:          error with playing
 */
public enum BMPlayerState {
    case notSetURL
    case readyToPlay
    case buffering
    case bufferFinished
    case playedToTheEnd
    case error
}

/**
 video aspect ratio types

 - `default`:    video default aspect
 - sixteen2NINE: 16:9
 - four2THREE:   4:3
 */
public enum BMPlayerAspectRatio: Int {
    case `default` = 0
    case sixteen2NINE
    case four2THREE
}

public protocol BMPlayerLayerViewDelegate: class {
    func bmPlayer(player: BMPlayerLayerView, playerStateDidChange state: BMPlayerState)
    func bmPlayer(player: BMPlayerLayerView, loadedTimeDidChange loadedDuration: TimeInterval, totalDuration: TimeInterval)
    func bmPlayer(player: BMPlayerLayerView, playTimeDidChange currentTime: TimeInterval, totalTime: TimeInterval)
    func bmPlayer(player: BMPlayerLayerView, playerIsPlaying playing: Bool)
}

open class BMPlayerLayerView: UIView {
    open weak var delegate: BMPlayerLayerViewDelegate?

    /// 视频跳转秒数置0
    open var seekTime = 0

    /// 播放属性
    open var playerItem: AVPlayerItem? {
        didSet {
            onPlayerItemChange()
        }
    }

    /// 播放属性
    open lazy var player: AVPlayer? = {
        if let item = self.playerItem {
            let player = AVPlayer(playerItem: item)
            return player
        }
        return nil
    }()

    open var videoGravity = AVLayerVideoGravity.resizeAspect {
        didSet {
            self.playerLayer?.videoGravity = videoGravity
        }
    }

    open var isPlaying: Bool = false {
        didSet {
            if oldValue != isPlaying {
                delegate?.bmPlayer(player: self, playerIsPlaying: isPlaying)
            }
        }
    }

    var aspectRatio: BMPlayerAspectRatio = .default {
        didSet {
            setNeedsLayout()
        }
    }

    /// 计时器
    var timer: Timer?

    fileprivate var urlAsset: AVURLAsset?

    fileprivate var lastPlayerItem: AVPlayerItem?
    /// playerLayer
    fileprivate var playerLayer: AVPlayerLayer?
    /// 音量滑杆
    fileprivate var volumeViewSlider: UISlider!
    /// 播放器的几种状态
    fileprivate var state = BMPlayerState.notSetURL {
        didSet {
            if state != oldValue {
                delegate?.bmPlayer(player: self, playerStateDidChange: state)
            }
        }
    }

    /// 是否为全屏
    fileprivate var isFullScreen = false
    /// 是否锁定屏幕方向
    fileprivate var isLocked = false
    /// 是否在调节音量
    fileprivate var isVolume = false
    /// 是否播放本地文件
    fileprivate var isLocalVideo = false
    /// slider上次的值
    fileprivate var sliderLastValue: Float = 0
    /// 是否点了重播
    fileprivate var repeatToPlay = false
    /// 播放完了
    fileprivate var playDidEnd = false
    // playbackBufferEmpty会反复进入，因此在bufferingOneSecond延时播放执行完之前再调用bufferingSomeSecond都忽略
    // 仅在bufferingSomeSecond里面使用
    fileprivate var isBuffering = false
    fileprivate var hasReadyToPlay = false
    fileprivate var shouldSeekTo: TimeInterval = 0

    private let drmQueue = DispatchQueue(label: "com.zinza.fairplay.queue")

    // MARK: - Actions

    open func playURL(url: URL) {
        let asset = AVURLAsset(url: url)
        playAsset(asset: asset)
    }

    open func playAsset(asset: AVURLAsset) {
        urlAsset = asset
        onSetVideoAsset()
        play()
    }

    open func play() {
        if let player = player {
            player.play()
            setupTimer()
            isPlaying = true
        }
    }

    open func pause() {
        player?.pause()
        isPlaying = false
        timer?.fireDate = Date.distantFuture
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - layoutSubviews

    open override func layoutSubviews() {
        super.layoutSubviews()
        switch aspectRatio {
        case .default:
            playerLayer?.videoGravity = AVLayerVideoGravity.resizeAspect
            playerLayer?.frame = bounds
        case .sixteen2NINE:
            playerLayer?.videoGravity = AVLayerVideoGravity.resize
            playerLayer?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.width / (16 / 9))
        case .four2THREE:
            playerLayer?.videoGravity = AVLayerVideoGravity.resize
            let _w = bounds.height * 4 / 3
            playerLayer?.frame = CGRect(x: (bounds.width - _w) / 2, y: 0, width: _w, height: bounds.height)
        }
    }

    open func resetPlayer() {
        // 初始化状态变量
        playDidEnd = false
        playerItem = nil
        seekTime = 0

        timer?.invalidate()

        pause()
        // 移除原来的layer
        playerLayer?.removeFromSuperlayer()
        // 替换PlayerItem为nil
        player?.replaceCurrentItem(with: nil)
        player?.removeObserver(self, forKeyPath: "rate")

        // 把player置为nil
        player = nil
    }

    open func prepareToDeinit() {
        resetPlayer()
    }

    open func onTimeSliderBegan() {
        if player?.currentItem?.status == AVPlayerItem.Status.readyToPlay {
            timer?.fireDate = Date.distantFuture
        }
    }

    open func seek(to secounds: TimeInterval, completion: (() -> Void)?) {
        if secounds.isNaN {
            return
        }
        setupTimer()
        if player?.currentItem?.status == AVPlayerItem.Status.readyToPlay {
            let draggedTime = CMTime(value: Int64(secounds), timescale: 1)
            player!.seek(to: draggedTime, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero, completionHandler: { _ in
                completion?()
            })
        } else {
            shouldSeekTo = secounds
        }
    }

    // MARK: - 设置视频URL

    fileprivate func onSetVideoAsset() {
        repeatToPlay = false
        playDidEnd = false
        configPlayer()
    }

    fileprivate func onPlayerItemChange() {
        if lastPlayerItem == playerItem {
            return
        }

        if let item = lastPlayerItem {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item)
            item.removeObserver(self, forKeyPath: "status")
            item.removeObserver(self, forKeyPath: "loadedTimeRanges")
            item.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        }

        lastPlayerItem = playerItem

        if let item = playerItem {
            NotificationCenter.default.addObserver(self, selector: #selector(moviePlayDidEnd),
                                                   name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                                   object: playerItem)

            item.addObserver(self, forKeyPath: "status", options: NSKeyValueObservingOptions.new, context: nil)
            item.addObserver(self, forKeyPath: "loadedTimeRanges", options: NSKeyValueObservingOptions.new, context: nil)
            // 缓冲区空了，需要等待数据
            item.addObserver(self, forKeyPath: "playbackBufferEmpty", options: NSKeyValueObservingOptions.new, context: nil)
            // 缓冲区有足够数据可以播放了
            item.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: NSKeyValueObservingOptions.new, context: nil)
        }
    }

    fileprivate func configPlayer() {
        player?.removeObserver(self, forKeyPath: "rate")
        urlAsset?.resourceLoader.preloadsEligibleContentKeys = true
        urlAsset?.resourceLoader.setDelegate(self, queue: drmQueue)
        playerItem = AVPlayerItem(asset: urlAsset!)
        player = AVPlayer(playerItem: playerItem!)
        player!.addObserver(self, forKeyPath: "rate", options: NSKeyValueObservingOptions.new, context: nil)

        playerLayer?.removeFromSuperlayer()
        playerLayer = AVPlayerLayer(player: player)
        playerLayer!.videoGravity = videoGravity

        layer.addSublayer(playerLayer!)

        setNeedsLayout()
        layoutIfNeeded()
    }

    func setupTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(playerTimerAction), userInfo: nil, repeats: true)
        timer?.fireDate = Date()
    }

    // MARK: - 计时器事件

    @objc fileprivate func playerTimerAction() {
        guard let playerItem = playerItem else { return }

        if playerItem.duration.timescale != 0 {
            let currentTime = CMTimeGetSeconds(player!.currentTime())
            let totalTime = TimeInterval(playerItem.duration.value) / TimeInterval(playerItem.duration.timescale)
            delegate?.bmPlayer(player: self, playTimeDidChange: currentTime, totalTime: totalTime)
        }
        updateStatus(includeLoading: true)
    }

    fileprivate func updateStatus(includeLoading: Bool = false) {
        if let player = player {
            if let playerItem = playerItem, includeLoading {
                if playerItem.isPlaybackLikelyToKeepUp || playerItem.isPlaybackBufferFull {
                    state = .bufferFinished
                } else if playerItem.status == .failed {
                    state = .error
                } else {
                    state = .buffering
                }
            }
            if player.rate == 0.0 {
                if player.error != nil {
                    state = .error
                    return
                }
                if let currentItem = player.currentItem {
                    if player.currentTime() >= currentItem.duration {
                        moviePlayDidEnd()
                        return
                    }
                    if currentItem.isPlaybackLikelyToKeepUp || currentItem.isPlaybackBufferFull {}
                }
            }
        }
    }

    // MARK: - Notification Event

    @objc fileprivate func moviePlayDidEnd() {
        if state != .playedToTheEnd {
            if let playerItem = playerItem {
                delegate?.bmPlayer(player: self,
                                   playTimeDidChange: CMTimeGetSeconds(playerItem.duration),
                                   totalTime: CMTimeGetSeconds(playerItem.duration))
            }

            state = .playedToTheEnd
            isPlaying = false
            playDidEnd = true
            timer?.invalidate()
        }
    }

    // MARK: - KVO

    open override func observeValue(forKeyPath keyPath: String?, of object: Any?, change _: [NSKeyValueChangeKey: Any]?, context _: UnsafeMutableRawPointer?) {
        if let item = object as? AVPlayerItem, let keyPath = keyPath {
            if item == playerItem {
                switch keyPath {
                case "status":
                    if item.status == .failed || player?.status == AVPlayer.Status.failed {
                        state = .error
                    } else if player?.status == AVPlayer.Status.readyToPlay {
                        state = .buffering
                        if shouldSeekTo != 0 {
                            print("BMPlayerLayer | Should seek to \(shouldSeekTo)")
                            seek(to: shouldSeekTo, completion: {
                                self.shouldSeekTo = 0
                                self.hasReadyToPlay = true
                                self.state = .readyToPlay
                            })
                        } else {
                            hasReadyToPlay = true
                            state = .readyToPlay
                        }
                    }

                case "loadedTimeRanges":
                    // 计算缓冲进度
                    if let timeInterVarl = self.availableDuration() {
                        let duration = item.duration
                        let totalDuration = CMTimeGetSeconds(duration)
                        delegate?.bmPlayer(player: self, loadedTimeDidChange: timeInterVarl, totalDuration: totalDuration)
                    }

                case "playbackBufferEmpty":
                    // 当缓冲是空的时候
                    if playerItem!.isPlaybackBufferEmpty {
                        state = .buffering
                        bufferingSomeSecond()
                    }
                case "playbackLikelyToKeepUp":
                    if item.isPlaybackBufferEmpty {
                        if state != .bufferFinished, hasReadyToPlay {
                            state = .bufferFinished
                            playDidEnd = true
                        }
                    }
                default:
                    break
                }
            }
        }

        if keyPath == "rate" {
            updateStatus()
        }
    }

    /**
     缓冲进度

     - returns: 缓冲进度
     */
    fileprivate func availableDuration() -> TimeInterval? {
        if let loadedTimeRanges = player?.currentItem?.loadedTimeRanges,
            let first = loadedTimeRanges.first {
            let timeRange = first.timeRangeValue
            let startSeconds = CMTimeGetSeconds(timeRange.start)
            let durationSecound = CMTimeGetSeconds(timeRange.duration)
            let result = startSeconds + durationSecound
            return result
        }
        return nil
    }

    /**
     缓冲比较差的时候
     */
    fileprivate func bufferingSomeSecond() {
        state = .buffering
        // playbackBufferEmpty会反复进入，因此在bufferingOneSecond延时播放执行完之前再调用bufferingSomeSecond都忽略

        if isBuffering {
            return
        }
        isBuffering = true
        // 需要先暂停一小会之后再播放，否则网络状况不好的时候时间在走，声音播放不出来
        player?.pause()
        let popTime = DispatchTime.now() + Double(Int64(Double(NSEC_PER_SEC) * 1.0)) / Double(NSEC_PER_SEC)

        DispatchQueue.main.asyncAfter(deadline: popTime) {
            // 如果执行了play还是没有播放则说明还没有缓存好，则再次缓存一段时间
            self.isBuffering = false
            if let item = self.playerItem {
                if !item.isPlaybackLikelyToKeepUp {
                    self.bufferingSomeSecond()
                } else {
                    // 如果此时用户已经暂停了，则不再需要开启播放了
                    self.state = BMPlayerState.bufferFinished
                }
            }
        }
    }
}

extension BMPlayerLayerView: AVAssetResourceLoaderDelegate {
    
    func getKeySaveLocation(_ assetId: String) -> URL {
        let persistantPathString = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        return URL(fileURLWithPath:persistantPathString! + "/" + assetId)
    }
    
    func returnLocalKey(request: AVAssetResourceLoadingRequest, context: Data) -> Bool {
        guard let contentInformationRequest = request.contentInformationRequest else {
            print("🔑", #function, "contentInformationError")
            return false
            
        }
        contentInformationRequest.contentType = AVStreamingKeyDeliveryPersistentContentKeyType
        
        // The CKC is correctly returned and is now send to the `AVPlayer` instance so we
        // can continue to play the stream.
        request.dataRequest!.respond(with: context)
        request.finishLoading()
        return true;
    }
    
    public func resourceLoader(_: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // We first check if a url is set in the manifest.
        guard let url = loadingRequest.request.url else {
            print("🔑", #function, "Unable to read the url/host data.")
            loadingRequest.finishLoading(with: NSError(domain: "com.zinza.error", code: -1, userInfo: nil))
            return false
        }
        print("🔑", #function, url)

        // When the url is correctly found we try to load the certificate date. Watch out! For this
        // example the certificate resides inside the bundle. But it should be preferably fetched from
        // the server.
        guard
            let certificateURL = Bundle.main.url(forResource: "zinza", withExtension: "cer"),
            let certificateData = try? Data(contentsOf: certificateURL) else {
            print("🔑", #function, "Unable to read the certificate data.")
            loadingRequest.finishLoading(with: NSError(domain: "com.zinza.error", code: -2, userInfo: nil))
            return false
        }

        // Request the Server Playback Context.
        let contentId = "bbc20290-e75f-4b09-a40d-5a2d594e4192"
        
        do {
            let persistentContentKeyContext = try Data(contentsOf:getKeySaveLocation(contentId))
            return returnLocalKey(request:loadingRequest,context:persistentContentKeyContext)
        } catch {
            print("🔑", #function, "can not get local key")
        }
        
        guard
            let contentIdData = contentId.data(using: String.Encoding.utf8),
            let spcData = try? loadingRequest.streamingContentKeyRequestData(
                forApp: certificateData,
                contentIdentifier: contentIdData,
                options: [AVAssetResourceLoadingRequestStreamingContentKeyRequestRequiresPersistentKey: true]),
            let dataRequest: AVAssetResourceLoadingDataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading(with: NSError(domain: "com.zinza.error", code: -3, userInfo: nil))
            print("🔑", #function, "Unable to read the SPC data.")
            return false
        }

        // Request the Content Key Context from the Key Server Module.
        let ckcURL = URL(string: "https://fps.ezdrm.com/api/licenses/\(contentId)")!
        var request = URLRequest(url: ckcURL)
        request.httpMethod = "POST"
        request.httpBody = spcData
        let session = URLSession(configuration: URLSessionConfiguration.default)
        let task = session.dataTask(with: request) { data, _, _ in
            if let data = data {
                do {
                    let persistantContentKeyContext = try loadingRequest.persistentContentKey(fromKeyVendorResponse: data, options: nil)
                    try persistantContentKeyContext.write(to: self.getKeySaveLocation(contentId), options: .atomic)
                    guard let contentInformationRequest = loadingRequest.contentInformationRequest else {
                        print("🔑", #function, "contentInformationError")
                        return

                    }
                    contentInformationRequest.contentType = AVStreamingKeyDeliveryPersistentContentKeyType
                    
                    // The CKC is correctly returned and is now send to the `AVPlayer` instance so we
                    // can continue to play the stream.
                    dataRequest.respond(with: persistantContentKeyContext)
                    loadingRequest.finishLoading()
                    return;
                }
                catch {
                    print("🔑", #function, "Error info: \(error)")
                    return
                }
            } else {
                print("🔑", #function, "Unable to fetch the CKC.")
                loadingRequest.finishLoading(with: NSError(domain: "com.zinza.error", code: -4, userInfo: nil))
            }
        }
        task.resume()

        return true
    }
}
