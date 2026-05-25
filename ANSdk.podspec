Pod::Spec.new do |s|
  s.name             = 'ANSdk'
  s.version          = '0.9.0'
  s.summary          = 'AntiNude SDK for iOS — on-device NSFW detector (NudeNet 320n).'
  s.description      = <<-DESC
    AntiNude SDK runs NSFW detection fully on-device using NudeNet 320n via
    ONNX Runtime. Image bytes never leave the phone; only the resulting
    verdict and per-class scores are reported to the AntiNude backend for
    dashboard analytics.
  DESC
  s.homepage         = 'https://github.com/AntiNude/an-sdk-ios'
  s.license          = { :type => 'MIT' }
  s.author           = { 'AntiNude' => 'support@antinude.site' }
  s.source           = { :git => 'https://github.com/AntiNude/an-sdk-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9']
  s.source_files     = 'Sources/ANSdk/**/*.swift'
  s.resources        = 'Sources/ANSdk/Resources/*.onnx'
  s.resource_bundles = {
    'ANSdk' => ['Sources/ANSdk/Resources/PrivacyInfo.xcprivacy']
  }
  s.frameworks       = 'Foundation', 'CoreGraphics', 'ImageIO', 'Accelerate'
  s.dependency 'onnxruntime-objc', '1.24.2'
end
