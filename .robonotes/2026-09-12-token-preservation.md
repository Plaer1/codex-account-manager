# Token preservation audit

- VS Code logs on September 12 report `refresh_token_invalidated` and `token_revoked`. These establish server rejection, not its cause. Unexpired JWTs are not proof of a valid session.
- Removed the proposed running-CLI restriction before deployment. Users switch in the manager, manually reload VS Code, and resume.
- Moved switch rollback snapshots after Desktop shutdown and re-resolve live identity at that point. Pre-shutdown snapshots could undo a refresh during shutdown on failure.
- Archive differing live and saved auth during outgoing saves. If both access tokens have issuance timestamps and the saved token is newer, retain it and archive the older live copy while allowing switching to proceed. Issuance time is a conservative ordering signal, not server validation of a refresh token.
- Re-authentication chooses whether to update live auth by verified identity rather than a possibly stale active-profile marker.
- Shell transaction tests pass, including an older-live/newer-saved regression. No production tokens were refreshed, overwritten, or replayed during the audit. Revoked sessions require login; automatic recovery from unverified historical tokens was not attempted.
- Root cause of server invalidation remains unproven. These changes address verified local overwrite hazards, not a claim to prevent every server revocation.
