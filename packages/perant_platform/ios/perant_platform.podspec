# SPDX-License-Identifier: GPL-3.0-only

Pod::Spec.new do |s|
  s.name             = 'perant_platform'
  s.version          = '0.1.0'
  s.summary          = 'PerAnt native platform diagnostics and runtime channel contracts.'
  s.description      = 'Reports actual host capabilities without simulating Linux or inference.'
  s.homepage         = 'https://github.com'
  s.license          = { :type => 'GPL-3.0-only', :file => '../LICENSE' }
  s.author           = 'PerAnt contributors'
  s.source           = { :path => '.' }
  s.source_files     = 'perant_platform/Sources/perant_platform/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '26.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
