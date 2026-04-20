/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/* ───────────────────────────────────────────────────────────────────────
 * metrovelox overlay: see apps/polaris-console/overlay/README.md
 * Applied by scripts/build-polaris-console.sh on top of the pinned
 * upstream submodule before `docker buildx build`; reverted afterwards
 * so the submodule working tree stays pristine.
 *
 * Upstream reads `sub` to identify the Polaris principal, but when the
 * token comes from an external IdP (Keycloak, Okta, etc.) `sub` is the
 * IdP user UUID, not the Polaris principal name.  We therefore prefer
 * the nested `polaris.principal_name` claim that our Keycloak protocol
 * mapper emits, then `preferred_username`, and fall back to `sub` only
 * as a last resort (for Polaris-internal client_credentials tokens
 * where `sub` already equals the principal name).
 * ──────────────────────────────────────────────────────────────────── */

import { type ClassValue, clsx } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/**
 * Decodes a JWT token and returns the payload
 * @param token - The JWT token string
 * @returns The decoded payload or null if invalid
 */
export function decodeJWT(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split(".")
    if (parts.length !== 3) {
      return null
    }
    const payload = parts[1]
    const decoded = atob(payload.replace(/-/g, "+").replace(/_/g, "/"))
    return JSON.parse(decoded)
  } catch (error) {
    console.error("Failed to decode JWT:", error)
    return null
  }
}

/**
 * Extracts the Polaris principal name from a JWT access token.
 *
 * Precedence (first non-empty wins):
 *   1. polaris.principal_name   — nested custom claim populated by the
 *                                 IdP (Keycloak protocol mapper); this
 *                                 is the canonical source for tokens
 *                                 issued by an external IdP.
 *   2. preferred_username        — standard OIDC claim; works for most
 *                                 Keycloak / Okta / Auth0 deployments
 *                                 when a custom mapper is not wired up.
 *   3. principal_name / principal — legacy flat-claim fallbacks.
 *   4. sub                       — last-resort fallback; matches
 *                                 Polaris-internal client_credentials
 *                                 tokens where `sub` is the principal.
 *   5. name                      — final fallback for exotic IdPs.
 */
export function getPrincipalNameFromToken(token: string): string | null {
  const decoded = decodeJWT(token)
  if (!decoded) {
    return null
  }
  const polaris = decoded.polaris as Record<string, unknown> | undefined
  return (
    (polaris?.principal_name as string) ||
    (decoded.preferred_username as string) ||
    (decoded.principal_name as string) ||
    (decoded.principal as string) ||
    (decoded.sub as string) ||
    (decoded.name as string) ||
    null
  )
}
