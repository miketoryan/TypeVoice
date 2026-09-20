import Foundation

struct ChatGPTClient {
    let accessToken: String
    let accountID: String?
    let cleanupModel: String

    func transcribe(fileURL: URL) async throws -> String {
        guard let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe") else {
            throw ChatGPTClientError.invalidURL
        }

        let boundary = "----typevoice-transcribe-\(UUID().uuidString.lowercased())"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        applyChatGPTHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audio = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"typevoice.wav\"\r\n")
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawText = object["text"] as? String
        else {
            throw ChatGPTClientError.invalidResponse
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ChatGPTClientError.emptyTranscription
        }
        return text
    }

    func cleanup(_ transcript: String) async throws -> String {
        guard let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw ChatGPTClientError.invalidURL
        }

        let instructions = """
        You are TypeVoice, a dictation cleanup engine.
        Return only the cleaned text, with no explanation, labels, markdown, or quotation marks.
        Keep the speaker's original language or mixed-language style. Never translate.
        Remove verbal filler such as 嗯、呃、那个、然后呢、uh, um, er only when they are filler.
        Remove stutters, accidental repetitions, duplicated phrases, abandoned fragments, and obvious false starts.
        Resolve self-corrections in favor of the speaker's final intended wording when that intent is clear.
        Preserve names, numbers, technical terms, meaning, tone, and level of formality.
        Add natural punctuation and paragraph breaks.
        Do not invent information and do not rewrite aggressively.
        If the input is already clean, return it nearly unchanged.
        """

        let payload: [String: Any] = [
            "model": cleanupModel,
            "instructions": instructions,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": transcript
                        ]
                    ]
                ]
            ],
            "tools": [],
            "tool_choice": "none",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": []
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        applyChatGPTHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        guard let stream = String(data: data, encoding: .utf8) else {
            throw ChatGPTClientError.invalidResponse
        }

        var result = ""
        for line in stream.components(separatedBy: .newlines) {
            guard line.hasPrefix("data:") else { continue }
            let jsonText = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if jsonText == "[DONE]" { continue }
            guard
                let jsonData = jsonText.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                continue
            }

            if
                (object["type"] as? String) == "response.output_text.delta",
                let delta = object["delta"] as? String
            {
                result += delta
            } else if result.isEmpty, let completed = extractOutputText(from: object) {
                result = completed
            }
        }

        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ChatGPTClientError.missingOutputText
        }
        return cleaned
    }

    private func applyChatGPTHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("TypeVoice/0.2 codex_cli_rs/0.153.4", forHTTPHeaderField: "User-Agent")
    }

    private func extractOutputText(from object: [String: Any]) -> String? {
        if let direct = object["output_text"] as? String, !direct.isEmpty {
            return direct
        }

        if
            let response = object["response"] as? [String: Any],
            let text = extractOutputTextFromResponse(response)
        {
            return text
        }

        return extractOutputTextFromResponse(object)
    }

    private func extractOutputTextFromResponse(_ response: [String: Any]) -> String? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        var parts: [String] = []

        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if
                    (part["type"] as? String) == "output_text",
                    let text = part["text"] as? String,
                    !text.isEmpty
                {
                    parts.append(text)
                }
            }
        }

        return parts.isEmpty ? nil : parts.joined()
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message: String
            if
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = object["error"] as? [String: Any],
                let serverMessage = error["message"] as? String
            {
                message = serverMessage
            } else if
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let detail = object["detail"] as? String
            {
                message = detail
            } else {
                message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            }
            throw ChatGPTClientError.server(status: http.statusCode, message: message)
        }
    }
}

enum ChatGPTClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case emptyTranscription
    case missingOutputText
    case server(status: Int, message: String)

    var isUnauthorized: Bool {
        if case .server(let status, _) = self {
            return status == 401
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ChatGPT endpoint."
        case .invalidResponse:
            return "Invalid response from ChatGPT."
        case .emptyTranscription:
            return "No speech was recognized."
        case .missingOutputText:
            return "ChatGPT returned no cleaned text."
        case .server(let status, let message):
            return "ChatGPT HTTP \(status): \(message)"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
