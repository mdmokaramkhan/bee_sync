#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint bee_sync.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'bee_sync'
  s.version          = '0.3.0'
  s.summary          = 'Durable, offline-first event delivery for Flutter.'
  s.description      = <<-DESC
Persistent SQLite event queue with batching, retries and consent controls,
plus native background delivery through BGTaskScheduler.
                       DESC
  s.homepage         = 'https://github.com/mdmokaramkhan/bee_sync'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Mohammad Mokaram Khan'
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks = 'BackgroundTasks'
  s.library = 'sqlite3'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'bee_sync_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
