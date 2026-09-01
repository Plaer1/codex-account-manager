import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum AccountIdentityTests {
    static func main() {
        let sharedTeamAccount = "shared-team-account"
        let upduck = AccountIdentity(
            subjectID: "user-upduck",
            email: "upduck@example.com",
            accountID: sharedTeamAccount
        )
        let bryant = AccountIdentity(
            subjectID: "user-bryant",
            email: "bryant@example.com",
            accountID: sharedTeamAccount
        )
        let refreshedUpduck = AccountIdentity(
            subjectID: "user-upduck",
            email: "upduck@example.com",
            accountID: "refreshed-account-context"
        )
        let emailOnlyUpduck = AccountIdentity(
            subjectID: "-",
            email: "UPDUCK@example.com",
            accountID: sharedTeamAccount
        )
        let emailOnlyBryant = AccountIdentity(
            subjectID: "-",
            email: "bryant@example.com",
            accountID: sharedTeamAccount
        )

        expect(!upduck.matches(bryant), "shared Team account IDs must not merge different users")
        expect(upduck.matches(refreshedUpduck), "a refreshed token for the same user must match")
        expect(emailOnlyUpduck.matches(upduck), "email should be the fallback when one token lacks a subject")
        expect(!emailOnlyUpduck.matches(emailOnlyBryant), "email fallback must reject a different user")

        let resolved = resolveLiveProfile(
            recordedProfile: "upduck1-slot",
            liveIdentity: bryant,
            candidates: [
                AccountIdentityCandidate(id: "upduck1-slot", identity: bryant, hasIdentityMismatch: true),
                AccountIdentityCandidate(id: "bryant-slot", identity: bryant, hasIdentityMismatch: false),
                AccountIdentityCandidate(id: "upduck2-slot", identity: upduck, hasIdentityMismatch: false)
            ]
        )
        expect(resolved == "bryant-slot", "a stale active marker must follow the verified live user")

        print("AccountIdentity tests passed")
    }
}
