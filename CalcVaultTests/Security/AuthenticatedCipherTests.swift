import Foundation
import XCTest
@testable import CalcVault

final class AuthenticatedCipherTests: XCTestCase {
    func testDummyExerciseRoundTripsAndRejectsTampering() throws {
        let result = try VaultKeyManager().runDummyExercise()

        XCTAssertTrue(result.roundTripSucceeded)
        XCTAssertTrue(result.tamperedCiphertextRejected)
        XCTAssertFalse(result.ciphertext.isEmpty)
        XCTAssertNotEqual(result.ciphertext, result.plaintext)
    }

    func testCipherRoundTripUsesFreshCiphertextForSyntheticFixture() throws {
        let cipher = AuthenticatedCipher()
        let key = cipher.generateKey()
        let fixture = Data("disposable Phase 0 fixture".utf8)

        let firstCiphertext = try cipher.encrypt(fixture, using: key)
        let secondCiphertext = try cipher.encrypt(fixture, using: key)

        XCTAssertEqual(try cipher.decrypt(firstCiphertext, using: key), fixture)
        XCTAssertEqual(try cipher.decrypt(secondCiphertext, using: key), fixture)
        XCTAssertNotEqual(firstCiphertext, secondCiphertext)
    }

    func testTamperedCiphertextFailsAuthentication() throws {
        let cipher = AuthenticatedCipher()
        let key = cipher.generateKey()
        let fixture = Data("synthetic authenticated data".utf8)
        var ciphertext = try cipher.encrypt(fixture, using: key)
        ciphertext[ciphertext.startIndex] ^= 0x01

        XCTAssertThrowsError(try cipher.decrypt(ciphertext, using: key)) { error in
            XCTAssertEqual(error as? AuthenticatedCipherError, .authenticationFailed)
        }
    }
}
