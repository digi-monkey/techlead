import { describe, expect, it } from 'vitest'

import { extractBootstrapParams, readAuthQuery } from './auth'

describe('readAuthQuery', () => {
  it('parses shared token and sensitive markers', () => {
    const query = readAuthQuery('?token=abc&bootstrap_id=boot&code=otp')
    expect(query.observe).toBe('abc')
    expect(query.control).toBe('abc')
    expect(query.bootstrapId).toBe('boot')
    expect(query.code).toBe('otp')
    expect(query.hasSensitive).toBe(true)
  })

  it('prefers scoped tokens over shared token', () => {
    const query = readAuthQuery('?token=base&observe_token=o1&control_token=c1')
    expect(query.observe).toBe('o1')
    expect(query.control).toBe('c1')
  })

  it('returns empty defaults for clean URL', () => {
    const query = readAuthQuery('')
    expect(query.observe).toBe('')
    expect(query.control).toBe('')
    expect(query.bootstrapId).toBe('')
    expect(query.code).toBe('')
    expect(query.hasSensitive).toBe(false)
  })
})

describe('extractBootstrapParams', () => {
  it('extracts from full URL', () => {
    const parsed = extractBootstrapParams('https://example.com/connect?bootstrap_id=b1&code=c1')
    expect(parsed).toEqual({ bootstrapId: 'b1', code: 'c1' })
  })

  it('extracts from plain query text', () => {
    const parsed = extractBootstrapParams('bootstrap_id=b2&code=c2')
    expect(parsed).toEqual({ bootstrapId: 'b2', code: 'c2' })
  })

  it('supports alias key names', () => {
    const parsed = extractBootstrapParams('?bootstrap=b3&one_time_code=c3')
    expect(parsed).toEqual({ bootstrapId: 'b3', code: 'c3' })
  })

  it('returns null when missing required fields', () => {
    expect(extractBootstrapParams('https://example.com/connect?bootstrap_id=only')).toBeNull()
    expect(extractBootstrapParams('')).toBeNull()
  })
})
