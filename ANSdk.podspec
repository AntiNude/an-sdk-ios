Pod::Spec.new do |s|
  s.name             = 'ANSdk'
  s.version          = '0.3.0'
  s.summary          = 'AntiNude SDK for iOS — on-device NSFW detector (mock in v0.3).'
  s.description      = <<-DESC
    AntiNude SDK runs NSFW classification fully on-device. Image bytes never
    leave the phone; only the resulting verdict is reported to the AntiNude
    backend for dashboard analytics.
  DESC
  s.homepage         = 'https://github.com/AntiNude/an-sdk-ios'
  s.license          = { :type => 'MIT' }
  s.author           = { 'AntiNude' => 'support@antinude.site' }
  s.source           = { :git => 'https://github.com/AntiNude/an-sdk-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.7']
  s.source_files     = 'Sources/ANSdk/**/*.swift'
  s.frameworks       = 'Foundation'
end
