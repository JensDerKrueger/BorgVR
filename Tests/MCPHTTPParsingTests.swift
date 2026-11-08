import Foundation
@testable import BorgVR

@main
struct MCPHTTPParsingTests {
  static func main() throws {
    let limit = 4 * 1024 * 1024
    func message(_ headers: String, body: String = "{}") -> Data {
      Data("POST /mcp HTTP/1.1\r\n\(headers)\r\n\r\n\(body)".utf8)
    }
    func reject(_ headers: String, as expected: MCPHTTPRequest.ParseError) throws {
      do {
        _ = try MCPHTTPRequest.parse(message(headers), maximumRequestBytes: limit)
        preconditionFailure("Malformed framing was accepted")
      } catch let error as MCPHTTPRequest.ParseError {
        switch (error, expected) {
          case (.malformed, .malformed), (.tooLarge, .tooLarge): break
          default: preconditionFailure("Wrong framing error")
        }
      }
    }
    let request = try MCPHTTPRequest.parse(message("Content-Length: 2"), maximumRequestBytes: limit)
    precondition(request?.body == Data("{}".utf8))
    let incompleteBody = try MCPHTTPRequest.parse(message("Content-Length: 2", body: "{"), maximumRequestBytes: limit)
    let incompleteHeader = try MCPHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length:".utf8), maximumRequestBytes: limit)
    precondition(incompleteBody == nil && incompleteHeader == nil)
    let headerOnly = message("Content-Length: 1000\r\nAuthorization: Bearer example", body: "")
    let head = try MCPHTTPRequest.parseHead(headerOnly, maximumRequestBytes: limit)
    precondition(head?.headers["authorization"] == "Bearer example" && head?.contentLength == 1000)
    precondition(head?.request(from: headerOnly) == nil, "Headers must be available before the body for authentication")
    for value in ["", "0", "-1", "+2", "1.5", "two", "2, 2", "\u{0662}"] {
      try reject("Content-Length: \(value)", as: .malformed)
    }
    try reject("Host: localhost", as: .malformed)
    try reject("Content-Length: 2\r\ncontent-length: 2", as: .malformed)
    try reject("Content-Length: 2\r\nAuthorization: Bearer first\r\nAuthorization: Bearer second", as: .malformed)
    try reject("Content-Length: 2\r\nOrigin: http://localhost\r\nOrigin: http://example.com", as: .malformed)
    try reject("Content-Length: 2\r\nHost: localhost\r\nHost: example.com", as: .malformed)
    try reject("Content-Length: 2\r\nTransfer-Encoding: chunked", as: .malformed)
    for value in [String(Int.max), String(repeating: "9", count: 100), String(limit)] {
      try reject("Content-Length: \(value)", as: .tooLarge)
    }
    let exact = message("Content-Length: 2")
    let atLimit = try MCPHTTPRequest.parse(exact, maximumRequestBytes: exact.count)
    precondition(atLimit?.body.count == 2)
    do {
      _ = try MCPHTTPRequest.parse(exact, maximumRequestBytes: exact.count - 1)
      preconditionFailure("Request limit was exceeded")
    } catch MCPHTTPRequest.ParseError.tooLarge {}
    try reject("Content-Length: 2\r\nX-Padding: \(String(repeating: "x", count: 16 * 1024))", as: .tooLarge)
    testDeadlines()
    print("MCP HTTP framing tests passed")
  }

  private static func testDeadlines() {
    var header = MCPConnectionDeadlines(now: 0)
    precondition(header.nextDeadline == 10)
    precondition(header.receivedBytes(1, at: 9))
    precondition(header.nextDeadline == 10 && header.expired(at: 10), "Bytes must not extend the header deadline")
    precondition(!header.receivedHeader(at: 10))

    var idle = MCPConnectionDeadlines(now: 0)
    precondition(idle.receivedHeader(at: 1) && idle.receivedBytes(0, at: 9))
    precondition(idle.nextDeadline == 10 && !idle.receivedBytes(1, at: 10), "Empty callbacks or late data must not revive a request")

    var body = MCPConnectionDeadlines(now: 0)
    precondition(body.receivedHeader(at: 1))
    for time in stride(from: 9.0, through: 54.0, by: 9) { precondition(body.receivedBytes(1, at: time)) }
    precondition(body.nextDeadline == 60 && body.expired(at: 60), "Activity must not extend the absolute request deadline")
    precondition(!body.finishedReceiving(at: 60))

    var command = MCPConnectionDeadlines(now: 0)
    precondition(command.receivedHeader(at: 1) && command.finishedReceiving(at: 2))
    precondition(command.nextDeadline == nil && !command.expired(at: 1000), "Receive deadlines must not abort long commands")
    precondition(command.beginSending(at: 1000) && command.nextDeadline == 1030)
    precondition(!command.beginSending(at: 1001), "Sending twice must not reset the send deadline")
    precondition(command.expired(at: 1030))
    command.close()
    precondition(command.nextDeadline == nil && !command.beginSending(at: 1040))

    var rejected = MCPConnectionDeadlines(now: 0)
    precondition(rejected.beginSending(at: 1) && rejected.nextDeadline == 31)
    precondition(!rejected.expired(at: 10), "A stale receive timer must not cancel a response")
  }
}
