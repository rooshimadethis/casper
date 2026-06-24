import XCTest
@testable import Casper

final class RuntimeEnvironmentTests: XCTestCase {
    func testIsRunningTestsIsTrueUnderXCTest() {
        XCTAssertTrue(RuntimeEnvironment.isRunningTests)
    }

    func testSuppressesAutomaticOnboardingWhenQuietInstallArgumentPresent() {
        XCTAssertTrue(
            RuntimeEnvironment.suppressesAutomaticOnboarding(
                arguments: ["Casper", "--quiet-install"],
                environment: [:]
            )
        )
    }

    func testSuppressesAutomaticOnboardingWhenQuietInstallEnvironmentPresent() {
        XCTAssertTrue(
            RuntimeEnvironment.suppressesAutomaticOnboarding(
                arguments: ["Casper"],
                environment: ["CASPER_QUIET_INSTALL": "1"]
            )
        )
    }

    func testDoesNotSuppressAutomaticOnboardingWithoutQuietInstallSignal() {
        XCTAssertFalse(
            RuntimeEnvironment.suppressesAutomaticOnboarding(
                arguments: ["Casper"],
                environment: [:]
            )
        )
    }
}
