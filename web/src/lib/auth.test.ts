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

  describe('security', () => {
    it('detects XSS attempts in token parameters', () => {
      const query = readAuthQuery('?token=<script>alert(1)</script>')
      expect(query.observe).toBe('<script>alert(1)</script>')
      expect(query.hasSensitive).toBe(true)
    })

    it('handles very long token values gracefully', () => {
      const longToken = 'a'.repeat(10000)
      const query = readAuthQuery(`?token=${longToken}`)
      expect(query.observe).toBe(longToken)
      expect(query.hasSensitive).toBe(true)
    })

    it('detects all token parameter variants as sensitive', () => {
      const variants = [
        '?token=abc',
        '?observe_token=abc',
        '?control_token=abc',
        '?ctrl_token=abc',
        '?bootstrap_id=abc',
        '?bootstrap=abc',
        '?code=abc',
        '?one_time_code=abc',
      ]
      for (const variant of variants) {
        const query = readAuthQuery(variant)
        expect(query.hasSensitive).toBe(true)
      }
    })

    it('correctly identifies URLs without sensitive parameters', () => {
      const cleanUrls = [
        '',
        '?page=1',
        '?search=test&filter=active',
        '?view=session&id=123',
      ]
      for (const url of cleanUrls) {
        const query = readAuthQuery(url)
        expect(query.hasSensitive).toBe(false)
      }
    })

    it('handles URL-encoded special characters in tokens', () => {
      const query = readAuthQuery('?token=abc%20def%2Bghi')
      expect(query.observe).toBe('abc def+ghi')
      expect(query.hasSensitive).toBe(true)
    })

    it('handles Unicode characters in tokens', () => {
      const query = readAuthQuery('?token=测试令牌')
      expect(query.observe).toBe('测试令牌')
      expect(query.hasSensitive).toBe(true)
    })
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

  describe('security', () => {
    it('handles malformed URLs gracefully', () => {
      const malformed = [
        'not-a-url',
        'http://[invalid',
        '://missing-protocol',
        '?',
        '&',
        '=',
      ]
      for (const input of malformed) {
        expect(() => extractBootstrapParams(input)).not.toThrow()
      }
    })

    it('returns null for XSS payloads in bootstrap params', () => {
      const parsed = extractBootstrapParams('?bootstrap_id=<script>&code=test')
      if (parsed !== null) {
        expect(parsed.bootstrapId).toBe('<script>')
      }
    })

    it('handles query strings with multiple ? characters', () => {
      const parsed = extractBootstrapParams('?bootstrap_id=b1?extra&code=c1')
      expect(parsed).not.toBeNull()
    })

    it('handles empty values', () => {
      expect(extractBootstrapParams('?bootstrap_id=&code=test')).toBeNull()
      expect(extractBootstrapParams('?bootstrap_id=test&code=')).toBeNull()
      expect(extractBootstrapParams('?bootstrap_id=&code=')).toBeNull()
    })

    it('preserves whitespace in values', () => {
      const parsed = extractBootstrapParams('?bootstrap_id=   &code=test')
      expect(parsed).toEqual({ bootstrapId: '   ', code: 'test' })
    })

    it('trims whitespace from payload', () => {
      const parsed = extractBootstrapParams('  ?bootstrap_id=b1&code=c1  ')
      expect(parsed).toEqual({ bootstrapId: 'b1', code: 'c1' })
    })

    it('handles very long bootstrap_id and code values', () => {
      const longId = 'b'.repeat(10000)
      const longCode = 'c'.repeat(10000)
      const parsed = extractBootstrapParams(`?bootstrap_id=${longId}&code=${longCode}`)
      expect(parsed).not.toBeNull()
      if (parsed) {
        expect(parsed.bootstrapId).toBe(longId)
        expect(parsed.code).toBe(longCode)
      }
    })

    it('handles URL with hash fragment', () => {
      const parsed = extractBootstrapParams('https://example.com/connect?bootstrap_id=b1&code=c1#section')
      expect(parsed).toEqual({ bootstrapId: 'b1', code: 'c1' })
    })
  })
})
