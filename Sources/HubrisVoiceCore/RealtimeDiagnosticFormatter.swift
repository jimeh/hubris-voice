import Foundation

public enum RealtimeDiagnosticFormatter {
  public static func errorSummary(_ error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain)(\(error.code)): \(sanitize(error.localizedDescription))"
  }

  public static func sanitize(_ value: String) -> String {
    let redactedBearer = replacingMatches(
      in: value,
      pattern: #"(?i)Bearer\s+[A-Za-z0-9._-]+"#,
      with: "Bearer <redacted>"
    )
    let redactedKeys = replacingMatches(
      in: redactedBearer,
      pattern: #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
      with: "<redacted-api-key>"
    )
    let withoutControls = redactedKeys.unicodeScalars.map { scalar in
      CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }.joined()
    let singleLine = withoutControls.split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return String(singleLine.prefix(2000))
  }

  private static func replacingMatches(
    in value: String,
    pattern: String,
    with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return value
    }
    let range = NSRange(value.startIndex..., in: value)
    return expression.stringByReplacingMatches(
      in: value,
      range: range,
      withTemplate: replacement
    )
  }
}
