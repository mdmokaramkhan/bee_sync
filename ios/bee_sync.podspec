Pod::Spec.new do |s|
  s.name             = 'bee_sync'
  s.version          = '0.3.1'
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

  # Declares UserDefaults use (a required-reason API); see Resources/PrivacyInfo.xcprivacy.
  s.resource_bundles = {'bee_sync_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
