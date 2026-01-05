platform :ios, '15.0'

target 'VideoCallAppGravi1' do
  use_frameworks!
  
  # Using WebRTC-SDK which is actively maintained
  pod 'WebRTC-SDK', '~> 125.6422.05'
end


post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end
end
