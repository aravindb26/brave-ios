// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Shared
import Preferences
import WebKit
import os.log
import AdServices

public class UserReferralProgram {

  /// Domains must match server HTTP header ones _exactly_
  private static let urpCookieOnlyDomains = ["coinbase.com"]
  public static let shared = UserReferralProgram()

  private static let apiKeyPlistKey = "API_KEY"

  struct HostUrl {
    static let staging = "https://laptop-updates.bravesoftware.com"
    static let prod = "https://laptop-updates.brave.com"
  }
  
  let adServicesURLString = "https://api-adservices.apple.com/api/v1/"

  // In case of network problems when looking for referrral code
  // we retry the call few times while the app is still alive.
  private struct ReferralLookupRetry {
    var timer: Timer?
    var currentCount = 0
    let retryLimit = 10
    let retryTimeInterval = AppConstants.buildChannel.isPublic ? 3.minutes : 1.minutes
  }

  private var referralLookupRetry = ReferralLookupRetry()

  let service: UrpService

  public init?() {
    // This should _probably_ correspond to the baseUrl for NTPDownloader
    let host = AppConstants.buildChannel == .debug ? HostUrl.staging : HostUrl.prod

    guard
      let apiKey = Bundle.main.getPlistString(
        for: UserReferralProgram.apiKeyPlistKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      Logger.module.error("Urp init error, failed to get values from Brave.plist.")
      return nil
    }

    guard let urpService = UrpService(host: host, apiKey: apiKey, adServicesURL: adServicesURLString) else { return nil }

    UrpLog.log("URP init, host: \(host)")

    self.service = urpService
  }

  /// Looks for referral and returns its landing page if possible.
  public func referralLookup(refCode: String? = nil, completion: @escaping (_ refCode: String?, _ offerUrl: String?) -> Void) {
    UrpLog.log("first run referral lookup")

    let referralBlock: (ReferralData?, UrpError?) -> Void = { [weak self] referral, error in
      guard let self = self else { return }

      if error == Growth.UrpError.endpointError {
        UrpLog.log("URP look up had endpoint error, will retry on next launch.")
        self.referralLookupRetry.timer?.invalidate()
        self.referralLookupRetry.timer = nil

        // Hit max retry attempts.
        if self.referralLookupRetry.currentCount > self.referralLookupRetry.retryLimit { return }

        self.referralLookupRetry.currentCount += 1
        self.referralLookupRetry.timer =
          Timer.scheduledTimer(
            withTimeInterval: self.referralLookupRetry.retryTimeInterval,
            repeats: true
          ) { [weak self] _ in
            self?.referralLookup(refCode: refCode) { refCode, offerUrl in
              completion(refCode, offerUrl)
            }
          }
        return
      }

      // Connection "succeeded"

      Preferences.URP.referralLookupOutstanding.value = false
      guard let ref = referral else {
        Logger.module.info("No referral code found")
        UrpLog.log("No referral code found")
        completion(nil, nil)
        return
      }

      if ref.isExtendedUrp() {
        completion(ref.referralCode, ref.offerPage)
        UrpLog.log("Extended referral code found, opening landing page: \(ref.offerPage ?? "404")")
        // We do not want to persist referral data for extended URPs
        return
      }

      Preferences.URP.downloadId.value = ref.downloadId
      Preferences.URP.referralCode.value = ref.referralCode

      self.referralLookupRetry.timer?.invalidate()
      self.referralLookupRetry.timer = nil

      UrpLog.log("Found referral: downloadId: \(ref.downloadId), code: \(ref.referralCode)")
      // In case of network errors or getting `isFinalized = false`, we retry the api call.
      self.initRetryPingConnection(numberOfTimes: 30)

      completion(ref.referralCode, nil)
    }

    // Since ref-code method may not be repeatable (e.g. clipboard was cleared), this should be retrieved from prefs,
    //  and not use the passed in referral code.
    service.referralCodeLookup(refCode: refCode, completion: referralBlock)
  }
  
  public func adCampaignLookup(completion: @escaping ((AdAttributionData)?, Error?) -> Void) {
    // Fetching ad attibution token
    do {
      let adAttributionToken = try AAAttribution.attributionToken()
      
      Task { @MainActor in
        do {
          let result = try await service.adCampaignTokenLookupQueue(adAttributionToken: adAttributionToken)
          completion(result, nil)
        } catch {
          Logger.module.info("Could not retrieve ad campaign attibution from ad services")
          completion(nil, error)
        }
      }
    } catch {
      Logger.module.info("Couldnt fetch attribute tokens with error: \(error)")
      completion(nil, error)
      return
    }
  }

  private func initRetryPingConnection(numberOfTimes: Int32) {
    if AppConstants.buildChannel.isPublic {
      // Adding some time offset to be extra safe.
      let offset = 1.hours
      let _30daysFromToday = Date().timeIntervalSince1970 + 30.days + offset
      Preferences.URP.nextCheckDate.value = _30daysFromToday
    } else {
      // For local and beta builds use a short timer
      Preferences.URP.nextCheckDate.value = Date().timeIntervalSince1970 + 10.minutes
    }

    Preferences.URP.retryCountdown.value = Int(numberOfTimes)
  }

  public func pingIfEnoughTimePassed() {
    if !DeviceInfo.hasConnectivity() {
      UrpLog.log("No internet connection, not sending update ping.")
      return
    }

    guard let downloadId = Preferences.URP.downloadId.value else {
      Logger.module.info("Could not retrieve download id model from preferences.")
      UrpLog.log("Update ping, no download id found.")
      return
    }

    guard let checkDate = Preferences.URP.nextCheckDate.value else {
      Logger.module.error("Could not retrieve check date from preferences.")
      return
    }

    let todayInSeconds = Date().timeIntervalSince1970

    if todayInSeconds <= checkDate {
      Logger.module.debug("Not enough time has passed for referral ping.")
      UrpLog.log("Not enough time has passed for referral ping.")
      return
    }

    UrpLog.log("Update ping")
    service.checkIfAuthorizedForGrant(with: downloadId) { initialized, error in
      guard let counter = Preferences.URP.retryCountdown.value else {
        Logger.module.error("Could not retrieve retry countdown from preferences.")
        return
      }

      var shouldRemoveData = false

      if error == .downloadIdNotFound {
        UrpLog.log("Download id not found on server.")
        shouldRemoveData = true
      }

      if initialized == true {
        UrpLog.log("Got initialized = true from server.")
        shouldRemoveData = true
      }

      // Last retry attempt
      if counter <= 1 {
        UrpLog.log("Last retry and failed to get data from server.")
        shouldRemoveData = true
      }

      if shouldRemoveData {
        UrpLog.log("Removing all referral data from device")

        Preferences.URP.downloadId.value = nil
        Preferences.URP.nextCheckDate.value = nil
        Preferences.URP.retryCountdown.value = nil
      } else {
        UrpLog.log("Network error or isFinalized returned false, decrementing retry counter and trying again next time.")
        // Decrement counter, next retry happens on next day
        Preferences.URP.retryCountdown.value = counter - 1
        Preferences.URP.nextCheckDate.value = checkDate + 1.days
      }
    }
  }

  /// Returns referral code and sets expiration day for its deletion from DAU pings(if needed).
  public class func getReferralCode() -> String? {
    if let referralCodeDeleteDate = Preferences.URP.referralCodeDeleteDate.value,
      Date().timeIntervalSince1970 >= referralCodeDeleteDate {
      Preferences.URP.referralCode.value = nil
      Preferences.URP.referralCodeDeleteDate.value = nil
      UrpLog.log("Enough time has passed, removing referral code data")
      return nil
    } else if let referralCode = Preferences.URP.referralCode.value {
      // Appending ref code to dau ping if user used installed the app via user referral program.
      if Preferences.URP.referralCodeDeleteDate.value == nil {
        UrpLog.log("Setting new date for deleting referral code.")
        let timeToDelete = AppConstants.buildChannel.isPublic ? 90.days : 20.minutes
        Preferences.URP.referralCodeDeleteDate.value = Date().timeIntervalSince1970 + timeToDelete
      }

      return referralCode
    }
    return nil
  }
}
