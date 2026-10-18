import Compression
import Foundation

struct HttpResponse {
  let status: Int
  /// Lower-cased header names.
  let headers: [String: String]
  let body: Data
}

/// POSTs a request body synchronously; throws for network failures. Called
/// from the uploader's own queue, never the main thread.
protocol HttpSender: AnyObject {
  func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws
    -> HttpResponse

  /// Aborts the request in progress, if any (background time ran out).
  func cancel()
}

final class URLSessionSender: HttpSender {
  private let session: URLSession
  private let lock = NSLock()
  private var current: URLSessionTask?

  init(configuration: URLSessionConfiguration = .ephemeral) {
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }

  func cancel() {
    lock.lock()
    current?.cancel()
    lock.unlock()
  }

  func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws
    -> HttpResponse
  {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body

    let done = DispatchSemaphore(value: 0)
    var result: Result<HttpResponse, Error> = .failure(URLError(.unknown))
    let task = session.dataTask(with: request) { data, response, error in
      if let error = error {
        result = .failure(error)
      } else if let http = response as? HTTPURLResponse {
        var lowered: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
          if let k = key as? String, let v = value as? String { lowered[k.lowercased()] = v }
        }
        result = .success(HttpResponse(status: http.statusCode, headers: lowered, body: data ?? Data()))
      } else {
        result = .failure(URLError(.badServerResponse))
      }
      done.signal()
    }
    lock.lock()
    current = task
    lock.unlock()
    task.resume()
    done.wait()
    lock.lock()
    current = nil
    lock.unlock()
    return try result.get()
  }
}

/// Refuses every redirect (spec/uploader_contract.md §4): URLSession would
/// re-send a POST as a body-less GET on 301/302/303, and a 2xx for that GET
/// would mark undelivered events as sent. The 3xx response is returned and
/// treated as retryable.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// gzip (RFC 1952). Foundation's compression gives raw DEFLATE, so the header
/// and CRC-32/ISIZE trailer are added here. Nil if compression failed; send
/// the body uncompressed then.
func gzip(_ data: Data) -> Data? {
  guard let deflated = deflateRaw(data) else { return nil }
  var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
  out.append(deflated)
  var crc = crc32(data).littleEndian
  var size = UInt32(truncatingIfNeeded: data.count).littleEndian
  withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
  withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
  return out
}

private func deflateRaw(_ data: Data) -> Data? {
  if data.isEmpty { return Data([0x03, 0x00]) }  // empty final fixed-Huffman block
  let capacity = data.count + data.count / 10 + 64
  var buffer = [UInt8](repeating: 0, count: capacity)
  let written = data.withUnsafeBytes { src in
    compression_encode_buffer(
      &buffer, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil,
      COMPRESSION_ZLIB)
  }
  return written == 0 ? nil : Data(buffer.prefix(written))
}

private let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
  var c = UInt32(n)
  for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
  return c
}

func crc32(_ data: Data) -> UInt32 {
  var crc: UInt32 = 0xFFFF_FFFF
  for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
  return crc ^ 0xFFFF_FFFF
}
