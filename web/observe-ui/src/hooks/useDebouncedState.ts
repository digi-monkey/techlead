import { useState, useEffect, useCallback } from 'react'

export function useDebouncedState<T>(initialValue: T, delay: number = 150): [T, T, (value: T) => void] {
  const [value, setValue] = useState<T>(initialValue)
  const [debouncedValue, setDebouncedValue] = useState<T>(initialValue)

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setDebouncedValue(value)
    }, delay)

    return () => {
      window.clearTimeout(timer)
    }
  }, [value, delay])

  const setValueDebounced = useCallback((newValue: T) => {
    setValue(newValue)
  }, [])

  return [value, debouncedValue, setValueDebounced]
}
