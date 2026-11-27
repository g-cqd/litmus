internal import Foundation

#if canImport(FoundationXML)
    internal import FoundationXML
#endif

final class XUnitReader: NSObject, XMLParserDelegate {
    var passed = 0, failed = 0, skipped = 0, depth = 0
    var inCase = false, caseFailed = false, caseSkipped = false, invalid = false
    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        depth += 1
        if depth > 64 { invalid = true; parser.abortParsing(); return }
        switch name {
        case "testcase":
            if inCase { invalid = true }
            inCase = true; caseFailed = false; caseSkipped = false
        case "failure":
            if !inCase { invalid = true }; caseFailed = true
        case "error": invalid = true  // Runner/process errors are not assertions.
        case "skipped":
            if !inCase { invalid = true }; caseSkipped = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "testcase" {
            if !inCase || caseFailed && caseSkipped { invalid = true }
            if caseFailed { failed += 1 } else if caseSkipped { skipped += 1 } else { passed += 1 }
            inCase = false
        }
        depth -= 1
    }
}
