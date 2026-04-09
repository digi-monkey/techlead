# Token Authentication Security Audit Report

**Project:** Techlead Observe UI  
**Audit Date:** 2026-04-02  
**Auditor:** AI Security Audit  
**Scope:** `web/observe-ui/src/lib/auth.ts` and related authentication flows  

---

## Executive Summary

The Techlead Observe UI implements a dual-token authentication system with observe (read) and control (write) capabilities. The system supports both modern HttpOnly cookie-based authentication and legacy URL token parameters for debugging. Overall, the implementation follows security best practices with proper token exchange mechanisms, but has several areas requiring attention.

**Overall Risk Rating:** Medium  
**Critical Issues:** 0  
**High Issues:** 1  
**Medium Issues:** 3  
**Low Issues:** 2  

---

## 1. Architecture Overview

### 1.1 Token Types

| Token Type | Purpose | Storage | Lifetime |
|------------|---------|---------|----------|
| `observe_token` | Read-only access (viewing sessions, events) | HttpOnly Cookie | 7 days |
| `control_token` | Write access (sending messages, control actions) | HttpOnly Cookie | 7 days |
| `bootstrap_id` | Temporary ticket for QR exchange | Memory (server) | 60s - 10min |
| `code` | One-time code for token exchange | Memory (server) | 60s - 10min |

### 1.2 Authentication Flow

```
┌─────────────┐     QR Scan      ┌─────────────┐     POST /auth/token/exchange     ┌─────────────┐
│   Backend   │ ───────────────> │   Frontend  │ ─────────────────────────────────> │   Backend   │
│ (generates  │   (bootstrap_id, │             │   (bootstrap_id + code)            │ (validates, │
│  ticket)    │    code in URL)  │             │                                    │ sets cookies)│
└─────────────┘                  └─────────────┘                                    └─────────────┘
                                                                                           │
                                                                                           ▼
                                                                                    ┌─────────────┐
                                                                                    │ HttpOnly    │
                                                                                    │ Cookies:    │
                                                                                    │ tl_observe  │
                                                                                    │ tl_control  │
                                                                                    └─────────────┘
```

---

## 2. Security Findings

### 2.1 HIGH: Token Transmission via URL Query Parameters

**Location:** 
- `web/observe-ui/src/lib/auth.ts` lines 9-37
- `web/observe-ui/src/App.tsx` lines 31-37, 217-236

**Description:**
The application accepts tokens through URL query parameters (`?token=`, `?observe_token=`, `?control_token=`) as a legacy/debugging mechanism. While the code does clean these from the URL after reading (via `history.replaceState`), the tokens are exposed in:
- Browser history
- Server access logs (if not properly configured)
- Referer headers when navigating to external sites
- HAR files and debugging captures

**Risk:**
High - Tokens could be leaked through various channels before URL cleanup occurs.

**Evidence:**
```typescript
// auth.ts - Line 10-12
const shared = params.get('token') ?? ''
const observe = params.get('observe_token') ?? shared
const control = params.get('control_token') ?? params.get('ctrl_token') ?? shared
```

```typescript
// App.tsx - Line 36-37
const [observeToken, setObserveToken] = useState(query.observe || cookieObserve)
const [controlToken, setControlToken] = useState(query.control || cookieControl)
```

**Recommendation:**
1. **Immediate:** Add a prominent warning when URL tokens are detected in production builds
2. **Short-term:** Restrict URL token authentication to development mode only (`import.meta.env.DEV`)
3. **Long-term:** Remove URL token support entirely in production builds

```typescript
// Recommended guard
if (!import.meta.env.DEV && query.hasSensitive) {
  console.error('URL token authentication is not allowed in production');
  // Redirect to error page or auth failure
}
```

---

### 2.2 MEDIUM: Missing CSRF Protection on Token Exchange

**Location:**
- `src/observe.zig` lines 1335-1387 (handleAuthTokenExchange)

**Description:**
The `/auth/token/exchange` endpoint accepts POST requests without CSRF token validation. While the bootstrap tickets are single-use and time-limited, a malicious website could potentially:
1. Trick a user into visiting a site with a pre-crafted QR code payload
2. If the user has a valid bootstrap ticket, the malicious site could exchange it for cookies

**Risk:**
Medium - Attack requires specific timing and user interaction, but is theoretically possible.

**Evidence:**
```zig
// observe.zig - No CSRF token validation
fn handleAuthTokenExchange(ctx: *ServerContext, req: *http.Server.Request) !void {
    if (req.head.method != .POST) return respondJson(req, .bad_request, ...);
    // ... body parsing and exchange logic without CSRF check
}
```

**Recommendation:**
1. Add `Origin` header validation to ensure requests come from the same origin
2. Consider implementing a CSRF token for the exchange endpoint
3. Add rate limiting per IP address for exchange attempts

---

### 2.3 MEDIUM: Cookie Security Attributes

**Location:**
- `src/observe.zig` lines 1367-1378

**Description:**
The HttpOnly cookies are set with `SameSite=Lax` but lack the `Secure` attribute. In production deployments without HTTPS, this could allow token theft via man-in-the-middle attacks.

**Evidence:**
```zig
const observe_cookie = try std.fmt.allocPrint(
    ctx.allocator,
    "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}",
    .{ AUTH_COOKIE_OBSERVE, ctx.observe_token, observe_age },
);
```

**Risk:**
Medium - Only affects non-HTTPS deployments, but should be enforced.

**Recommendation:**
1. Add `Secure` attribute when `TECHLEAD_EXTERNAL_URL` starts with `https://`
2. Or make it configurable via environment variable

```zig
const secure_flag = if (ctx.external_url and std.mem.startsWith(u8, ctx.external_url.?, "https://")) "; Secure" else "";
const observe_cookie = try std.fmt.allocPrint(
    ctx.allocator,
    "{s}={s}; Path=/; HttpOnly; SameSite=Lax{?s}; Max-Age={d}",
    .{ AUTH_COOKIE_OBSERVE, ctx.observe_token, secure_flag, observe_age },
);
```

---

### 2.4 MEDIUM: Token Display in Debug Mode

**Location:**
- `web/observe-ui/src/App.tsx` lines 299-307, 343-364

**Description:**
The debug mode (`isDebugBuild`) allows direct viewing and editing of tokens in the UI. While this is intended for development, there's no additional confirmation or warning before displaying sensitive tokens.

**Risk:**
Medium - Could lead to accidental token exposure if screenshots are shared.

**Recommendation:**
1. Add a confirmation dialog before showing tokens
2. Add a visual warning banner when debug mode is active
3. Consider blurring tokens by default with a reveal button

---

### 2.5 LOW: No Token Rotation on Privilege Escalation

**Location:**
- `web/observe-ui/src/App.tsx` lines 124-138

**Description:**
When exchanging a bootstrap ticket, the system does not rotate or invalidate existing tokens. While this is generally acceptable, it means:
- Old tokens remain valid even after a new exchange
- There's no way to force re-authentication after a certain period

**Risk:**
Low - This is standard behavior for many systems, but limits security controls.

**Recommendation:**
1. Consider implementing token rotation on each exchange (optional feature)
2. Add a "logout" functionality that explicitly clears cookies and requires re-authentication

---

### 2.6 LOW: URL Parameter Parsing Permissive

**Location:**
- `web/observe-ui/src/lib/auth.ts` lines 43-64

**Description:**
The `extractBootstrapParams` function accepts various URL formats including plain query strings without protocol validation. While this flexibility is useful for QR scanning, it could potentially allow unexpected input formats.

**Risk:**
Low - No immediate security impact identified, but increases attack surface.

**Evidence:**
```typescript
// Accepts various formats including plain text
const query = trimmed.includes('?') ? trimmed.slice(trimmed.indexOf('?') + 1) : trimmed
return fromSearchParams(new URLSearchParams(query))
```

**Recommendation:**
1. Add validation to ensure bootstrap_id and code match expected format (alphanumeric, specific length)
2. Sanitize inputs before processing

---

## 3. Security Strengths

### 3.1 Proper HttpOnly Cookie Usage ✅

Tokens are stored in HttpOnly cookies which:
- Are inaccessible to JavaScript (XSS protection)
- Are automatically sent with requests
- Support `SameSite=Lax` to prevent CSRF in most scenarios

### 3.2 Bootstrap Ticket Security ✅

The QR exchange mechanism implements:
- Single-use tickets (consumed on exchange)
- Time-limited validity (60 seconds - 10 minutes)
- Cryptographically random 32-character hex tokens
- Server-side storage only (not in database)

### 3.3 URL Cleanup ✅

Sensitive parameters are removed from URL after reading:
```typescript
// App.tsx - Line 218-221
const removeQuerySecrets = () => {
  if (query.hasSensitive) {
    history.replaceState({}, '', location.pathname)
  }
}
```

### 3.4 Token Scope Separation ✅

Separate observe (read) and control (write) tokens provide:
- Principle of least privilege
- Ability to share read-only access safely
- Reduced impact if observe token is compromised

### 3.5 Request ID Deduplication ✅

Control endpoints implement request ID deduplication to prevent replay attacks:
```zig
fn isDuplicateRequestId(ctx: *ServerContext, request_id: []const u8) bool {
    // 5-minute TTL on request IDs
    const now = std.time.timestamp();
    // ... cleanup and check logic
}
```

---

## 4. XSS Analysis

### 4.1 DOM XSS Risk Assessment

**Status:** Low Risk

The authentication system does not:
- Render token values directly into DOM without sanitization
- Use `innerHTML` or `dangerouslySetInnerHTML` with token values
- Execute token values as code

The token display in debug mode uses controlled React state:
```typescript
<input value={observeToken} onChange={(e) => setObserveToken(e.target.value.trim())} />
```

This is safe as React's JSX escaping prevents XSS.

### 4.2 Recommendation

Add Content Security Policy (CSP) headers to further mitigate XSS risks:
```
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'
```

---

## 5. CSRF Analysis

### 5.1 Current CSRF Protection

The system relies on:
1. **SameSite=Lax cookies** - Prevents CSRF from cross-site POST requests in most modern browsers
2. **Custom API requests** - API calls use `fetch` with proper headers

### 5.2 Vulnerabilities

- `SameSite=Lax` allows top-level navigation with GET requests
- No additional CSRF tokens for state-changing operations
- The exchange endpoint is particularly vulnerable as it's a POST without additional validation

### 5.3 Recommendation

Implement additional CSRF protection:
1. Add `Origin` header validation for all state-changing endpoints
2. Consider SameSite=Strict for enhanced protection
3. Add CSRF tokens for sensitive operations

---

## 6. Token Lifecycle

### 6.1 Token Expiration

| Token | Lifetime | Refresh Mechanism |
|-------|----------|-------------------|
| observe/control | 7 days | Server restart or explicit rotation |
| bootstrap_id | 60s - 10min | None (single-use) |
| code | 60s - 10min | None (single-use) |

### 6.2 Token Revocation

**Current State:** No explicit token revocation mechanism

**Recommendation:**
1. Add a logout endpoint that clears cookies
2. Implement token blacklisting for immediate revocation
3. Add token version numbers for rapid invalidation

---

## 7. Testing Recommendations

### 7.1 Unit Tests

The existing tests in `auth.test.ts` cover basic parsing but should be extended:

```typescript
// Additional test cases to add:
- XSS payload in token parameters
- Malformed URL handling
- Very long token values (overflow protection)
- Unicode and special characters in tokens
```

### 7.2 Integration Tests

- Token exchange flow end-to-end
- Cookie attribute validation
- CSRF attack simulation
- Token expiration behavior

### 7.3 Security Tests

- Penetration testing for exchange endpoint
- Cookie security attribute verification
- Rate limiting validation

---

## 8. Compliance Checklist

| Requirement | Status | Notes |
|------------|--------|-------|
| OWASP Top 10 - Broken Access Control | ⚠️ Partial | URL token mechanism bypasses cookie protection |
| OWASP Top 10 - Cryptographic Failures | ✅ Pass | Proper random token generation |
| OWASP Top 10 - Injection | ✅ Pass | No SQL injection or command injection risks |
| OWASP Top 10 - Insecure Design | ⚠️ Partial | Debug features in production code |
| OWASP Top 10 - Security Misconfiguration | ⚠️ Partial | Secure flag missing on cookies |
| OWASP ASVS V2 - Authentication | ✅ Pass | Multi-factor via QR exchange |
| OWASP ASVS V3 - Session Management | ⚠️ Partial | No explicit logout mechanism |

---

## 9. Summary of Recommendations

### Immediate (High Priority)
1. Restrict URL token authentication to development mode only
2. Add `Origin` header validation to `/auth/token/exchange`

### Short-term (Medium Priority)
3. Add `Secure` cookie attribute for HTTPS deployments
4. Add confirmation dialog for debug token display
5. Implement rate limiting on exchange endpoint

### Long-term (Low Priority)
6. Add explicit logout functionality
7. Implement token rotation mechanism
8. Add CSP headers
9. Remove URL token support in production

---

## 10. Conclusion

The Techlead Observe UI authentication system demonstrates good security fundamentals with proper use of HttpOnly cookies, cryptographic randomness, and single-use bootstrap tickets. The primary concerns are the URL token mechanism (which should be restricted to development) and the lack of CSRF protection on the exchange endpoint.

The overall risk is **Medium** - the system is suitable for production use with the recommended mitigations implemented.

---

*End of Report*
