patches=[
('                var text = native','                ProbeTrace.event("pdf-native", ["page": i + 1, "native": native])\n                var text = native'),
('        let request = VNRecognizeTextRequest()', '        try ProbeTrace.image("ocr-input", image)\n        let request = VNRecognizeTextRequest()'),
('        try VNImageRequestHandler(cgImage: image).perform([request])','        try ProbeTrace.configure(request)\n        ProbeTrace.event("perform-begin")\n        do { try VNImageRequestHandler(cgImage: image).perform([request]) }\n        catch { ProbeTrace.error("perform-error", error); throw error }\n        ProbeTrace.observations(request)'),
('                    guard !native.isEmpty else { throw error }','                    ProbeTrace.error("pdf-ocr-catch", error)\n                    guard !native.isEmpty else { throw error }'),
('        let hash = SHA256.hash(data: data)', '        let priorTraceScope = ProbeTrace.threadScope\n        defer { ProbeTrace.threadScope = priorTraceScope }\n        try ProbeTrace.beginInput(data, url.pathExtension)\n        let hash = SHA256.hash(data: data)'),
('        return ExtractedDocument(title:', '        ProbeTrace.event("extract-result", ["lines": blocks.map(\\.text), "warnings": warnings])\n        return ExtractedDocument(title:')
]

def instrument(source):
    for old,new in patches:
        assert source.count(old)==1, old
        source=source.replace(old,new)
    return source
