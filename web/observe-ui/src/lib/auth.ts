export type AuthQuery = {
  observe: string
  control: string
  bootstrapId: string
  code: string
  hasSensitive: boolean
}

function parseAuthQuery(params: URLSearchParams): AuthQuery {
  const shared = params.get('token') ?? ''
  const observe = params.get('observe_token') ?? shared
  const control = params.get('control_token') ?? params.get('ctrl_token') ?? shared
  const bootstrapId = params.get('bootstrap_id') ?? params.get('bootstrap') ?? ''
  const code = params.get('code') ?? params.get('one_time_code') ?? ''

  const hasSensitive =
    Boolean(shared) ||
    Boolean(observe) ||
    Boolean(control) ||
    Boolean(bootstrapId) ||
    Boolean(code) ||
    params.has('observe_token') ||
    params.has('control_token') ||
    params.has('ctrl_token') ||
    params.has('token') ||
    params.has('bootstrap_id') ||
    params.has('bootstrap') ||
    params.has('one_time_code')

  return {
    observe,
    control,
    bootstrapId,
    code,
    hasSensitive,
  }
}

export function readAuthQuery(search: string): AuthQuery {
  return parseAuthQuery(new URLSearchParams(search))
}

export function extractBootstrapParams(raw: string): { bootstrapId: string; code: string } | null {
  const trimmed = raw.trim()
  if (!trimmed) return null

  const fromSearchParams = (params: URLSearchParams) => {
    const bootstrapId = params.get('bootstrap_id') ?? params.get('bootstrap') ?? ''
    const code = params.get('code') ?? params.get('one_time_code') ?? ''
    if (!bootstrapId || !code) return null
    return { bootstrapId, code }
  }

  try {
    const url = new URL(trimmed)
    const parsed = fromSearchParams(url.searchParams)
    if (parsed) return parsed
  } catch {
    // Keep fallback parsing below for plain query string payloads.
  }

  const query = trimmed.includes('?') ? trimmed.slice(trimmed.indexOf('?') + 1) : trimmed
  return fromSearchParams(new URLSearchParams(query))
}
