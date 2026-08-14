#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_xray.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_xray'
  s.version          = '0.1.0'
  s.summary          = 'Android-first Flutter client plugin for Xray'
  s.description      = <<-DESC
Android-first Flutter plugin providing embedded Xray client control.
iOS contains a registration stub but VPN operation is currently unsupported.
                       DESC
  s.homepage         = 'https://github.com/zikwall/flutter_xray'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Amir Ziari' => 'ahz85955@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
