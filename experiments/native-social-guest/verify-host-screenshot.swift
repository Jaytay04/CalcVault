import AppKit
import Vision

guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("Expected a simulator screenshot\n", stderr)
    exit(2)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(cgImage: cgImage).perform([request])
let text = (request.results ?? [])
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
print("Synthetic screenshot OCR:\n\(text)")
guard text.localizedCaseInsensitiveContains("Synthetic native guest") else {
    fputs("The synthetic guest was not visible in the host\n", stderr)
    exit(1)
}
