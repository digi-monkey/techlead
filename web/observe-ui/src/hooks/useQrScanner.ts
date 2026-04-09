import { useCallback, useEffect, useRef, useState } from 'react'

type UseQrScannerOptions = {
  onPayload: (rawPayload: string, setStatus: (status: string) => void) => void | Promise<void>
}

export function useQrScanner({ onPayload }: UseQrScannerOptions) {
  const [scannerStatus, setScannerStatus] = useState('scanner idle')
  const [scannerActive, setScannerActive] = useState(false)

  const scannerVideoRef = useRef<HTMLVideoElement | null>(null)
  const scannerStreamRef = useRef<MediaStream | null>(null)
  const scannerTimerRef = useRef<number | null>(null)
  const scannerBusyRef = useRef(false)

  const stopScanner = useCallback(() => {
    if (scannerTimerRef.current != null) {
      window.clearInterval(scannerTimerRef.current)
      scannerTimerRef.current = null
    }

    scannerBusyRef.current = false

    if (scannerStreamRef.current) {
      for (const track of scannerStreamRef.current.getTracks()) {
        track.stop()
      }
      scannerStreamRef.current = null
    }

    if (scannerVideoRef.current) {
      scannerVideoRef.current.pause()
      scannerVideoRef.current.srcObject = null
    }

    setScannerActive(false)
  }, [])

  const startScanner = useCallback(async () => {
    if (scannerActive) return

    if (!navigator.mediaDevices?.getUserMedia) {
      setScannerStatus('camera API unavailable in this browser')
      return
    }

    const Detector = window.BarcodeDetector
    if (typeof Detector !== 'function') {
      setScannerStatus('live scan unsupported, paste scanned link below')
      return
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: { facingMode: { ideal: 'environment' } },
      })

      const video = scannerVideoRef.current
      if (!video) {
        for (const track of stream.getTracks()) track.stop()
        setScannerStatus('scanner view unavailable')
        return
      }

      scannerStreamRef.current = stream
      video.srcObject = stream
      await video.play()

      const detector = new Detector({ formats: ['qr_code'] })
      setScannerStatus('scanner active, point camera at QR')
      setScannerActive(true)
      scannerBusyRef.current = false

      scannerTimerRef.current = window.setInterval(() => {
        const currentVideo = scannerVideoRef.current
        if (!currentVideo || currentVideo.readyState < 2) return
        if (scannerBusyRef.current) return

        scannerBusyRef.current = true
        void detector
          .detect(currentVideo)
          .then((codes) => {
            const rawValue =
              codes.find((item) => typeof item.rawValue === 'string' && item.rawValue.trim().length > 0)?.rawValue ?? ''
            if (!rawValue) return

            setScannerStatus('QR detected, authorizing...')
            stopScanner()
            void Promise.resolve(onPayload(rawValue, setScannerStatus)).catch((err) => {
              setScannerStatus(`authorization failed: ${(err as Error).message}`)
            })
          })
          .catch((err) => {
            // Keep scanning; decode errors are expected for most frames.
            console.error('[useQrScanner] QR decode error:', err);
          })
          .finally(() => {
            scannerBusyRef.current = false
          })
      }, 280)
    } catch (err) {
      stopScanner()
      setScannerStatus(`camera error: ${(err as Error).message}`)
    }
  }, [onPayload, scannerActive, stopScanner])

  useEffect(() => {
    return () => {
      stopScanner()
    }
  }, [stopScanner])

  return {
    scannerStatus,
    scannerActive,
    scannerVideoRef,
    startScanner,
    stopScanner,
  }
}
