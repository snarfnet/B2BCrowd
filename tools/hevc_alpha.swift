// ProRes 4444（透明つき）を、iOS で再生できる透明つき HEVC に変換する。
// 使い方: swift tools/hevc_alpha.swift in.mov out.mov
import AVFoundation

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: dst)
let asset = AVURLAsset(url: src)
guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQualityWithAlpha) else {
    print("no export session"); exit(1)
}
ex.outputURL = dst
ex.outputFileType = .mov
let done = DispatchSemaphore(value: 0)
ex.exportAsynchronously { done.signal() }
done.wait()
if ex.status != .completed { print("FAILED", ex.error as Any); exit(1) }
let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
print("OK", dst.lastPathComponent, size)
