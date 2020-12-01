//
// Copyright © 2020 NHSX. All rights reserved.
//

import Common
import Foundation
import TestSupport
import XCTest
@testable import Domain

@available(iOS 13.7, *)
class ExposureWindowEventEndpointTests: XCTestCase {
    private let endpoint = ExposureWindowEventEndpoint(
        riskInfo: ExposureRiskInfo(
            riskScore: 131.44555790888523,
            riskScoreVersion: 2,
            day: GregorianDay(year: 2020, month: 11, day: 12),
            isConsideredRisky: true
        ),
        latestAppVersion: Version(major: 3, minor: 12),
        postcode: "LL44"
    )
    
    func testEncoding() throws {
        let expected = HTTPRequest.post("/submission/mobile-analytics-events", body: .json("""
        {
          "events": [
            {
              "payload": {
                "infectiousness": "high",
                "riskScore": 131.44555790888523,
                "riskCalculationVersion": 2,
                "scanInstances": [
                  {
                    "minimumAttenuation": 97,
                    "secondsSinceLastScan": 201,
                    "typicalAttenuation": 0
                  }
                ],
                "date": "2020-11-12T00:00:00Z"
              },
              "type": "exposureWindow",
              "version": 1
            }
          ],
          "metadata": {
            "deviceModel": "\(UIDevice.current.modelName)",
            "latestApplicationVersion": "3.12",
            "operatingSystemVersion": "\(UIDevice.current.systemVersion)",
            "postalDistrict": "LL44"
          }
        }
        """)).withCanonicalJSONBody()
        
        let exposureWindow: ExposureNotificationExposureWindow = MockExposureWindow(
            enScanInstances: [
                MockScanInstance(
                    minimumAttenuation: 97,
                    secondsSinceLastScan: 201,
                    typicalAttenuation: 0
                ),
            ],
            date: Calendar.utc.date(from: DateComponents(year: 2020, month: 11, day: 12))!,
            infectiousness: .high
        )
        let actual = try endpoint.request(for: exposureWindow).withCanonicalJSONBody()
        TS.assert(actual, equals: expected)
    }
}