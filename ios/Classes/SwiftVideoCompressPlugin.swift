import Flutter
import AVFoundation

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    private var exporter: AVAssetExportSession? = nil
    private var stopCommand = false
    private let channel: FlutterMethodChannel
    private let avController = AvController()
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger())
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        switch call.method {
        case "getByteThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getByteThumbnail(path, quality, position, result)
        case "getFileThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getFileThumbnail(path, quality, position, result)
        case "getMediaInfo":
            let path = args!["path"] as! String
            getMediaInfo(path, result)
        case "compressVideo":
            let path = args!["path"] as! String
            let compressPath = args!["compressPath"] as? String
            let quality = args!["quality"] as! NSNumber
            let deleteOrigin = args!["deleteOrigin"] as! Bool
            let startTime = args!["startTime"] as? Double
            let duration = args!["duration"] as? Double
            let includeAudio = args!["includeAudio"] as? Bool
            let ignoreAudio = args!["ignoreAudio"] as? Bool
            let frameRate = args!["frameRate"] as? Int
            let bitRate = args!["bitRate"] as? Int
            compressVideo2(path, quality, deleteOrigin, startTime, duration, includeAudio,
                          frameRate, bitRate, compressPath, result)
        case "cancelCompression":
            cancelCompression(result)
        case "deleteAllCache":
            Utility.deleteFile(Utility.basePath(), clear: true)
            result(true)
        case "setLogLevel":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func getBitMap(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult)-> Data?  {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }
        
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        
        let timeScale = CMTimeScale(track.nominalFrameRate)
        let time = CMTimeMakeWithSeconds(Float64(truncating: position),preferredTimescale: timeScale)
        guard let img = try? assetImgGenerate.copyCGImage(at:time, actualTime: nil) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }
    
    private func getByteThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        if let bitmap = getBitMap(path,quality,position,result) {
            result(bitmap)
        }
    }
    
    private func getFileThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        Utility.deleteFile(path)
        if let bitmap = getBitMap(path,quality,position,result) {
            guard (try? bitmap.write(to: url)) != nil else {
                return result(FlutterError(code: channelName,message: "getFileThumbnail error",details: "getFileThumbnail error"))
            }
            result(Utility.excludeFileProtocol(url.absoluteString))
        }
    }
    
    public func getMediaInfoJson(_ path: String)->[String : Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }
        
        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset
        
        let orientation = avController.getVideoOrientation(path)
        
        let title = avController.getMetaDataByTag(metadataAsset,key: "title")
        let author = avController.getMetaDataByTag(metadataAsset,key: "author")
        
        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength
        
        let size = track.naturalSize.applying(track.preferredTransform)
        
        let width = abs(size.width)
        let height = abs(size.height)
        
        let dictionary = [
            "path":Utility.excludeFileProtocol(path),
            "title":title,
            "author":author,
            "width":width,
            "height":height,
            "duration":duration,
            "filesize":filesize,
            "orientation":orientation
            ] as [String : Any?]
        return dictionary
    }
    
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
    }
    
    
    @objc private func updateProgress(timer:Timer) {
        let asset = timer.userInfo as! AVAssetExportSession
        if(!stopCommand) {
            channel.invokeMethod("updateProgress", arguments: "\(String(describing: asset.progress * 100))")
        }
    }
    
    private func getExportPreset(_ quality: NSNumber)->String {
        switch(quality) {
        case 1:
            return AVAssetExportPresetLowQuality    
        case 2:
            return AVAssetExportPresetMediumQuality
        case 3:
            return AVAssetExportPresetHighestQuality
        case 4:
            return AVAssetExportPreset640x480
        case 5:
            return AVAssetExportPreset960x540
        case 6:
            return AVAssetExportPreset1280x720
        case 7:
            return AVAssetExportPreset1920x1080
        default:
            return AVAssetExportPresetMediumQuality
        }
    }
    
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            let compressionVideoTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compressionVideoTrack!.preferredTransform = sourceVideoTrack.preferredTransform
            try? compressionVideoTrack!.insertTimeRange(timeRange, of: sourceVideoTrack, at: CMTime.zero)
        } else {
            return sourceVideoTrack.asset!
        }
        
        return composition    
    }
    
    private func compressVideo(_ path: String,_ quality: NSNumber,_ deleteOrigin: Bool,_ startTime: Double?,
                               _ duration: Double?,_ includeAudio: Bool?,_ frameRate: Int?,_ bitrate: Int?,
                               _ compressionPath: String?,
                               _ result: @escaping FlutterResult) {
        let sourceVideoUrl = Utility.getPathUrl(path)
        let sourceVideoType = "mp4"
        
        let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        let sourceVideoTrack = avController.getTrack(sourceVideoAsset)

        let compressionUrl: URL
            if let nonEmptyCompressionPath = compressionPath, nonEmptyCompressionPath != "" { // 当压缩路径不为空时
                compressionUrl = Utility.getPathUrl(nonEmptyCompressionPath)
            } else { // 当压缩路径为空时
                let uuid = NSUUID()
                compressionUrl = Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid.uuidString).\(sourceVideoType)")
            }
        let timescale = sourceVideoAsset.duration.timescale
        let minStartTime = Double(startTime ?? 0)
        
        let videoDuration = sourceVideoAsset.duration.seconds
        let minDuration = Double(duration ?? videoDuration)
        let maxDurationTime = minStartTime + minDuration < videoDuration ? minDuration : videoDuration
        
        let cmStartTime = CMTimeMakeWithSeconds(minStartTime, preferredTimescale: timescale)
        let cmDurationTime = CMTimeMakeWithSeconds(maxDurationTime, preferredTimescale: timescale)
        let timeRange: CMTimeRange = CMTimeRangeMake(start: cmStartTime, duration: cmDurationTime)
        
        let isIncludeAudio = includeAudio != nil ? includeAudio! : true
        
        let session = getComposition(isIncludeAudio, timeRange, sourceVideoTrack!)
        
        let exporter = AVAssetExportSession(asset: session, presetName: getExportPreset(quality))!
        
        exporter.outputURL = compressionUrl
        exporter.outputFileType = AVFileType.mp4
        exporter.shouldOptimizeForNetworkUse = true
        
        // 设置默认帧率
        let defaultFrameRate = 25
        let actualFrameRate = frameRate ?? defaultFrameRate
        let videoComposition = AVMutableVideoComposition(propertiesOf: sourceVideoAsset)
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(actualFrameRate))
        exporter.videoComposition = videoComposition

        if !isIncludeAudio {
            exporter.timeRange = timeRange
        }
        
        Utility.deleteFile(compressionUrl.absoluteString)
        
        let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.updateProgress),
                                         userInfo: exporter, repeats: true)
        
        exporter.exportAsynchronously(completionHandler: {
            timer.invalidate()
            if(self.stopCommand) {
                self.stopCommand = false
                var json = self.getMediaInfoJson(path)
                json["isCancel"] = true
                let jsonString = Utility.keyValueToJson(json)
                return result(jsonString)
            }
            if deleteOrigin {
                let fileManager = FileManager.default
                do {
                    if fileManager.fileExists(atPath: path) {
                        try fileManager.removeItem(atPath: path)
                    }
                    self.exporter = nil
                    self.stopCommand = false
                }
                catch let error as NSError {
                    print(error)
                }
            }
            var json = self.getMediaInfoJson(Utility.excludeEncoding(compressionUrl.path))
            json["isCancel"] = false
            let jsonString = Utility.keyValueToJson(json)
            result(jsonString)
        })
        self.exporter = exporter
    }

     private func compressVideo2(_ path: String,_ quality: NSNumber,_ deleteOrigin: Bool,_ startTime: Double?,
                                   _ duration: Double?,_ includeAudio: Bool?,_ frameRate: Int?,_ bitrate: Int?,
                                   _ compressionPath: String?,
                                   _ result: @escaping FlutterResult) {
         //原视频地址
         let sourceVideoUrl = Utility.getPathUrl(path)
         let sourceVideoType = "mp4"
         // 创建音视频输入asset
         let asset = AVAsset(url: sourceVideoUrl)
         //压缩视频地址
         let compressionUrl: URL
             if let nonEmptyCompressionPath = compressionPath, nonEmptyCompressionPath != "" { // 当压缩路径不为空时
                 compressionUrl = Utility.getPathUrl(nonEmptyCompressionPath)
             } else { // 当压缩路径为空时
                 let uuid = NSUUID()
                 compressionUrl = Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid.uuidString).\(sourceVideoType)")
             }
         // 创建音视频Reader和Writer
         guard let reader = try? AVAssetReader(asset: asset),
               let writer = try? AVAssetWriter.init(outputURL: compressionUrl, fileType: AVFileType.mp4) else {
             self.cancelCompression(result)
             return
         }
         Utility.deleteFile(compressionUrl.absoluteString)
         //视频输出配置
         let configVideoOutput: [String : Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_422YpCbCr8)
         ] as! [String: Any]

         //压缩配置
         let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,  //码率
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
         ]
         let videoCodec: String = AVVideoCodecType.h264.rawValue //视频编码
         var videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec, //视频编码
            AVVideoWidthKey: 1280,//视频宽（必须填写正确，否则压缩后有问题）
            AVVideoHeightKey: 720,//视频高（必须填写正确，否则压缩后有问题）
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill//设置视频缩放方式
         ]

         //video part
         guard let videoTrack: AVAssetTrack = (asset.tracks(withMediaType: .video)).first else {
             self.cancelCompression(result)
             return
         }
         let originFrameRate = Int(round(videoTrack.nominalFrameRate))
         //获取原视频的角度
         let degree = self.degressFromVideoFileWithURL(videoTrack: videoTrack)
         //获取原视频的宽高，如果是手机拍摄，一般是宽大，高小，如果是手机自带录屏，那么是高大，宽小
         let naturalSize = videoTrack.naturalSize
         if naturalSize.width < naturalSize.height {
            videoSettings[AVVideoWidthKey] = 720
            videoSettings[AVVideoHeightKey] = 1280
         }
         let videoOutput: AVAssetReaderTrackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: configVideoOutput)
         let videoInput: AVAssetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
         //视频写入的旋转（这句很重要）
         if let transform = self.getAffineTransform(degree: degree, videoTrack: videoTrack) {
            videoInput.transform = transform
         }
         if reader.canAdd(videoOutput) {
            reader.add(videoOutput)
         }
         if writer.canAdd(videoInput) {
            writer.add(videoInput)
         }

         //audio part
         //音频输出配置
         let configAudioOutput: [String : Any] = [AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM)] as! [String: Any]
         let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 96000, // 码率
            AVSampleRateKey: 44100, // 采样率
            AVNumberOfChannelsKey : 1
         ]
         var audioTrack: AVAssetTrack?
         var audioOutput: AVAssetReaderTrackOutput?
         var audioInput: AVAssetWriterInput?
         if let track = (asset.tracks(withMediaType: .audio)).first {
             audioTrack = track
             if let audioTrack = audioTrack {
                     audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: configAudioOutput)
                     audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                 }
                 if let audioOutput = audioOutput, reader.canAdd(audioOutput) {
                     reader.add(audioOutput)
                 }
                 if let audioInput = audioInput, writer.canAdd(audioInput) {
                     writer.add(audioInput)
                 }
         }

         // 开始读写
         reader.startReading()
         writer.startWriting()
         writer.startSession(atSourceTime: .zero)

         let group = DispatchGroup()
         let processingQueue = DispatchQueue(label: "processingQueue")
         let totalVideoFrames = Int(videoTrack.timeRange.duration.seconds * Double(frameRate ?? 30))
         var processedVideoFrames = 0
         var totalAudioFrames: Int?
         var processedAudioFrames = 0
         let ratio = originFrameRate / (frameRate ?? 30)
         if let audioTrack = audioTrack {
            totalAudioFrames = Int(audioTrack.timeRange.duration.seconds * 44100)
//             print("音频帧数：\(totalAudioFrames)")
         }
         group.enter()
         videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoOutQueue"), using: {
            var completedOrFailed = false
            while (videoInput.isReadyForMoreMediaData) && !completedOrFailed {
                let sampleBuffer: CMSampleBuffer? = videoOutput.copyNextSampleBuffer()
                if sampleBuffer != nil {
                    let result = videoInput.append(sampleBuffer!)
                    //处理进度
                    processingQueue.sync {
                    let ratioDouble = Double(ratio)
                    let safeRatio = ratioDouble != 0 ? ratioDouble : 1.0  // 处理除零情况
                    processedVideoFrames += Int(round(1.0 / safeRatio))
                      let videoProgress = Double(processedVideoFrames) / Double(totalVideoFrames)
                      var overallProgress = videoProgress
                      if let totalAudioFrames = totalAudioFrames {
                      let audioProgress = Double(processedAudioFrames) / Double(totalAudioFrames)
                      overallProgress = (videoProgress + audioProgress) / 2
                      // print("2222->  audioProgress: \(audioProgress), videoProgress: \(videoProgress)")
                      }
                      //更新进度
                      self.updateProgress2(progress: overallProgress)
                    }
                } else {
                    completedOrFailed = true
                    videoInput.markAsFinished()
                    group.leave()
                    break
                }
         }
        })
             if let audio = audioTrack, let audioOutput = audioOutput, let audioInput = audioInput {
                 group.enter()
                 audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audioOutQueue"), using: {
                     var completedOrFailed = false
                     while (audioInput.isReadyForMoreMediaData) && !completedOrFailed {
                         let sampleBuffer: CMSampleBuffer? = audioOutput.copyNextSampleBuffer()
                         if sampleBuffer != nil {
                             let result = audioInput.append(sampleBuffer!)
                             processingQueue.sync {
                             // 更新已处理的样本数
                             let numSamples = CMSampleBufferGetNumSamples(sampleBuffer!)
                                processedAudioFrames += numSamples
                                                            let videoProgress = Double(processedVideoFrames) / Double(totalVideoFrames)
                                                            var overallProgress = videoProgress
                                                            if let totalAudioFrames = totalAudioFrames {
                                                                let audioProgress = Double(processedAudioFrames) / Double(totalAudioFrames)
                                                                overallProgress = (videoProgress + audioProgress) / 2
//                                                                 print("11111->  audioProgress: \(audioProgress), videoProgress: \(videoProgress)")
                                                            }
                                                             //更新进度
                                    self.updateProgress2(progress: overallProgress)
                             }
                         } else {
                             completedOrFailed = true
                             audioInput.markAsFinished()
                             group.leave()
                             break
                         }
                     }
                 })
             }

             group.notify(queue: DispatchQueue.main) {
                 // 检查 AVAssetReader 的状态，如果它还在读取中，则取消读取操作
                 if reader.status == .reading {
                     reader.cancelReading()
                 }
                 // 根据 AVAssetWriter 的不同状态进行不同的处理
                 switch writer.status {
                 case .writing:
                     // 如果还在写入中，则调用 finishWriting 方法完成写入操作，并在完成后执行回调
                     writer.finishWriting(completionHandler: {
                         // 在主线程上延迟 0.3 秒后执行后续操作
                         DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.3, execute: {
                         print("完成啦啦啦啦啦啦啦")
                              if self.stopCommand {
                                                  self.stopCommand = false
                                                  var json = self.getMediaInfoJson(path)
                                                  json["isCancel"] = true
                                                  let jsonString = Utility.keyValueToJson(json)
                                                  result(jsonString) // 直接调用，移除 return
                                              } else {
                                                  if deleteOrigin {
                                                      let fileManager = FileManager.default
                                                      do {
                                                          if fileManager.fileExists(atPath: path) {
                                                              try fileManager.removeItem(atPath: path)
                                                          }
                                                          self.stopCommand = false
                                                      } catch {
                                                          print(error)
                                                      }
                                                  }
                                                  var json = self.getMediaInfoJson(Utility.excludeEncoding(compressionUrl.path))
                                                  json["isCancel"] = false
                                                  let jsonString = Utility.keyValueToJson(json)
                                                  result(jsonString) // 直接调用，移除 return
                                              }
                        })
                     })
                 case .cancelled:
                     self.cancelCompression(result)
                 case .failed:
                     // 如果写入操作失败，打印失败信息和错误详情
                     print("$$$ compress failed", writer.error)
                     self.cancelCompression(result)
                 case .completed:
                     // 如果写入操作已完成，打印完成信息
                     print("$$$ compress completed")
                 case .unknown:
                     // 如果写入操作状态未知，打印未知信息
                     print("$$$ compress unknown")
                 }
             }
    }

    @objc private func updateProgress2(progress: Double) {
        if(!stopCommand) {
            channel.invokeMethod("updateProgress", arguments: "\(progress * 100)")
        }
    }

    //获取视频的角度
    private func degressFromVideoFileWithURL(videoTrack: AVAssetTrack)->Int {
        var degress = 0

        let t: CGAffineTransform = videoTrack.preferredTransform
        if(t.a == 0 && t.b == 1.0 && t.c == -1.0 && t.d == 0){
            // Portrait
            degress = 90
        }else if(t.a == 0 && t.b == -1.0 && t.c == 1.0 && t.d == 0){
            // PortraitUpsideDown
            degress = 270
        }else if(t.a == 1.0 && t.b == 0 && t.c == 0 && t.d == 1.0){
            // LandscapeRight
            degress = 0
        }else if(t.a == -1.0 && t.b == 0 && t.c == 0 && t.d == -1.0){
            // LandscapeLeft
            degress = 180
        }
        return degress
    }


    private func getAffineTransform(degree: Int, videoTrack: AVAssetTrack) -> CGAffineTransform? {
        var translateToCenter: CGAffineTransform?
        var mixedTransform: CGAffineTransform?

        switch degree {
        case 90:
            // 视频旋转90度，home按键在左
            translateToCenter = CGAffineTransform(translationX: videoTrack.naturalSize.height, y: 0.0)
            if let translate = translateToCenter {
               mixedTransform = translate.rotated(by: Double.pi / 2)
            }
        case 180:
            // 视频旋转180度，home按键在上
            translateToCenter = CGAffineTransform(translationX: videoTrack.naturalSize.width, y: videoTrack.naturalSize.height)
            if let translate = translateToCenter {
                mixedTransform = translate.rotated(by: Double.pi)
            }
        case 270:
            // 视频旋转270度，home按键在右
            translateToCenter = CGAffineTransform(translationX: 0.0, y: videoTrack.naturalSize.width)
            if let translate = translateToCenter {
               mixedTransform = translate.rotated(by: Double.pi / 2 * 3)
            }
        default:
            break
        }

        return mixedTransform
    }

    private func cancelCompression(_ result: FlutterResult) {
        stopCommand = true
        exporter?.cancelExport()
        result("")
    }
    
}
