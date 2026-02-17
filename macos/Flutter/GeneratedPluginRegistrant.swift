//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import flutter_secure_storage_darwin
import package_info_plus
import photo_manager
import sodium_libs
import sqflite_darwin
import video_player_avfoundation
import wakelock_plus

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  FlutterSecureStorageDarwinPlugin.register(with: registry.registrar(forPlugin: "FlutterSecureStorageDarwinPlugin"))
  FPPPackageInfoPlusPlugin.register(with: registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
  PhotoManagerPlugin.register(with: registry.registrar(forPlugin: "PhotoManagerPlugin"))
  SodiumLibsPlugin.register(with: registry.registrar(forPlugin: "SodiumLibsPlugin"))
  SqflitePlugin.register(with: registry.registrar(forPlugin: "SqflitePlugin"))
  FVPVideoPlayerPlugin.register(with: registry.registrar(forPlugin: "FVPVideoPlayerPlugin"))
  WakelockPlusMacosPlugin.register(with: registry.registrar(forPlugin: "WakelockPlusMacosPlugin"))
}
