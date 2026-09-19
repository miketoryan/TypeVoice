import Foundation

struct OpenAIClient {
    let apiKey: String
    let baseURL: String
    let transcriptionModel: String
    let cleanupModel: String

    func transcribe(fileURL: URL) async throws -> String {
        let endpoint = try makeEndpoint("audio/transcriptions")
        let boundary = "TypeVoice-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audio = try Data(contentsOf: fileURL)
        var body = Data()

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("\(transcriptionModel)\r\n")

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"typevoice.wav\"\r\n")
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIError.emptyTranscription }
        return text
    }

    func cleanup(_ transcript: String) async throws -> String {
        let endpoint = try makeEndpoint("responses")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let instructions = """
        You are TypeVoice, a dictation cleanup engine.
        Return only the cleaned text, with no explanation or labels.
        Keep the speaker's original language or mixed-language style. Never translate.
        Remove verbal filler such as 嗯、呃、那个、然后呢、uh, um, er only when they are filler.
        Remove stutters, accidental repetitions, duplicated phrases, abandoned fragments, and obvious false starts.
        Resolve self-corrections in favor of the speaker's final intended wording when that intent is clear.
        Preserve names, numbers, technical terms, meaning, tone, and level of formality.
        Add natural punctuation and paragraph breaks.
        Do not invent information and do not rewrite aggressively.
        If the input is already clean, return it nearly unchanged.
        """

        let payload = CleanupRequest(
            model: cleanupModel,
            instructions: instructions,
            input: transcript
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let direct = object?["output_text"] as? String {
            let cleaned = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }

        if let output = object?["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    guard
                        (part["type"] as? String) == "output_text",
                        let text = part["text"] as? String
                    else { continue }
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }

        throw OpenAIError.missingOutputText
    }

    private func makeEndpoint(_ path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/" + path) else {
            throw OpenAIError.invalidBaseURL
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message: String
            if
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = object["error"] as? [String: Any],
                let serverMessage = error["message"] as? String
            {
                message = serverMessage
            } else {
                message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            }
            throw OpenAIError.server(status: http.statusCode, message: message)
        }
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct CleanupRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
}

enum OpenAIError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case emptyTranscription
    case missingOutputText
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid API base URL."
        case .invalidResponse:
            return "Invalid response from transcription service."
        case .emptyTranscription:
            return "No speech was recognized."
        case .missingOutputText:
            return "The cleanup model returned no text."
        case .server(let status, let message):
            return "API \(status): \(message)"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
