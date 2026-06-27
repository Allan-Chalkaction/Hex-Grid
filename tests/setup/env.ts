// Test setup (runs before each test file via vitest `setupFiles`).
//
// Node 24 ships global `File` and `Blob` but NOT `FileReader`. papaparse's
// FileStreamer prefers an async `FileReader` (it falls back to `FileReaderSync`
// only when `FileReader` is undefined, and that fallback throws in node). The
// CSV-import unit tests pass a real `File` to `importCsv`, so we install a
// minimal async `FileReader` polyfill backed by `Blob.text()`. Browser/CI envs
// that already define `FileReader` are left untouched.
//
// This is a TEST-ONLY shim — it adds no runtime dependency to the app.
interface MinimalFileReader {
  result: string | null;
  error: unknown;
  onload: ((ev: { target: MinimalFileReader }) => void) | null;
  onerror: ((ev: { target: MinimalFileReader }) => void) | null;
  readAsText(blob: Blob): void;
}

if (typeof (globalThis as { FileReader?: unknown }).FileReader === 'undefined') {
  class FileReaderPolyfill implements MinimalFileReader {
    result: string | null = null;
    error: unknown = null;
    onload: ((ev: { target: MinimalFileReader }) => void) | null = null;
    onerror: ((ev: { target: MinimalFileReader }) => void) | null = null;

    readAsText(blob: Blob): void {
      blob
        .text()
        .then((text) => {
          this.result = text;
          this.onload?.({ target: this });
        })
        .catch((err) => {
          this.error = err;
          this.onerror?.({ target: this });
        });
    }
  }
  (globalThis as { FileReader?: unknown }).FileReader = FileReaderPolyfill;
}
