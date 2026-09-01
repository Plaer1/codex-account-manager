import Foundation

struct AccountIdentity: Codable, Equatable {
    let subjectID: String
    let email: String
    let accountID: String

    var isUsable: Bool {
        !normalizedSubjectID.isEmpty || !normalizedEmail.isEmpty
    }

    func matches(_ other: AccountIdentity) -> Bool {
        if !normalizedSubjectID.isEmpty && !other.normalizedSubjectID.isEmpty {
            return normalizedSubjectID == other.normalizedSubjectID
        }

        if !normalizedEmail.isEmpty && !other.normalizedEmail.isEmpty {
            return normalizedEmail == other.normalizedEmail
        }

        return false
    }

    private var normalizedSubjectID: String {
        normalize(subjectID)
    }

    private var normalizedEmail: String {
        normalize(email)
    }

    private func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "-" ? "" : trimmed.lowercased()
    }
}

struct AccountIdentityCandidate {
    let id: String
    let identity: AccountIdentity
    let hasIdentityMismatch: Bool
}

func resolveLiveProfile(
    recordedProfile: String,
    liveIdentity: AccountIdentity,
    candidates: [AccountIdentityCandidate]
) -> String {
    guard liveIdentity.isUsable else { return "" }

    if let recorded = candidates.first(where: { $0.id == recordedProfile }),
       !recorded.hasIdentityMismatch,
       liveIdentity.matches(recorded.identity) {
        return recorded.id
    }

    let matches = candidates.filter {
        !$0.hasIdentityMismatch && liveIdentity.matches($0.identity)
    }
    return matches.count == 1 ? matches[0].id : ""
}
