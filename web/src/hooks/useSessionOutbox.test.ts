import { describe, expect, it } from 'vitest'

import { nextRetryDelayMs } from './useSessionOutbox'

describe('nextRetryDelayMs', () => {
  it('uses exponential backoff from attempt 1', () => {
    expect(nextRetryDelayMs(1)).toBe(1200)
    expect(nextRetryDelayMs(2)).toBe(2400)
    expect(nextRetryDelayMs(3)).toBe(4800)
  })

  it('caps exponential growth and hard upper bound', () => {
    expect(nextRetryDelayMs(6)).toBe(30000)
    expect(nextRetryDelayMs(20)).toBe(30000)
  })
})
