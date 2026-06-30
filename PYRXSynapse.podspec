Pod::Spec.new do |s|
  s.name             = 'PYRXSynapse'
  s.version          = '0.2.0'
  s.summary          = 'PYRX Synapse iOS SDK — events, identity, push, in-app messaging, privacy controls.'
  s.description      = <<-DESC
    Native iOS SDK for the PYRX Synapse customer engagement platform.
    Provides event tracking with a disk-backed offline queue, identity
    management with anonymous-to-known merge, push notification
    registration + delivery + cold-start attribution, in-app messaging
    with rendering-callback delivery, GDPR-compliant privacy controls,
    and diagnostics — all from a thread-safe Swift actor on iOS 14+.
  DESC

  s.homepage         = 'https://synapse.pyrx.tech'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'PYRX' => 'support@pyrx.tech' }
  s.source           = {
    :git => 'https://github.com/PYRX-Tech/pyrx-synapse-ios.git',
    :tag => "v#{s.version}"
  }

  s.swift_versions          = ['5.9']
  s.ios.deployment_target   = '14.0'

  s.source_files = 'Sources/PYRXSynapse/**/*.swift'

  s.frameworks = 'Foundation', 'Security'
end
