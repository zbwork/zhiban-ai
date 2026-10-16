#
# 本地 vendored pod: 阿里云 DingRTC 3.0 macOS SDK (F16 Phase 1 音频通话)。
# 二进制 (DingRTC.framework / libffmpeg.dylib) 不入库, 见同目录 README.md 重建。
#
Pod::Spec.new do |s|
  s.name             = 'DingRTC'
  s.version          = '3.9.0'
  s.summary          = 'Aliyun DingRTC macOS SDK (vendored local-only for F16 RTC).'
  s.description      = 'Vendored Aliyun DingRTC 3.0 macOS audio/video SDK. Binaries downloaded locally, not committed.'
  s.homepage         = 'https://help.aliyun.com/document_detail/2640099.html'
  s.license          = { :type => 'Commercial', :text => 'Aliyun DingRTC SDK — commercial license.' }
  s.author           = { 'Aliyun' => 'https://help.aliyun.com' }
  s.platform         = :osx, '10.15'
  # 本地 :path pod, source 不会被拉取; 留官方下载地址作记录。
  s.source           = { :http => 'https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/mac/3.9.0/DingRTC_macOS_SDK_3_9_0.zip' }

  # F16 v0.7 会议能力扩展: MoziWhiteboard(互动白板) + libhbal_se/.nn 模型(智能降噪) 随 SDK zip 一起
  # 由 scripts/install_dingrtc_macos_sdk.sh 复制进本目录 (二进制仍不入库)。
  s.vendored_frameworks = 'DingRTC.framework', 'MoziWhiteboard.framework'
  s.vendored_libraries  = 'libffmpeg.dylib', 'libhbal_se.dylib'
  s.resources           = 'model/*.nn'

  # DingRTC 运行期依赖的系统库 (见官方 Mac 集成文档 2640099)。
  s.frameworks = 'CoreMedia', 'CoreAudio', 'AudioToolbox', 'AVFoundation'
  s.libraries  = 'c++', 'resolv', 'z'

  s.pod_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=*]' => '',
    'ENABLE_BITCODE' => 'NO'
  }
end
