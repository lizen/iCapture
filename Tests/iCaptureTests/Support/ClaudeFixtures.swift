import Foundation

enum ClaudeFixtures {
    /// Claude Messages API 스트림 모양의 SSE 본문.
    /// `message_start` → (선택) thinking 블록 → 텍스트 블록 델타들 → `message_delta` → `message_stop`.
    static func sse(_ chunks: [String], thinkingFirst: Bool = false, stopReason: String = "end_turn") -> String {
        var out = ""
        out += event("message_start", ["type": "message_start", "message": ["id": "msg_1", "role": "assistant"]])
        var index = 0
        if thinkingFirst {
            out += event("content_block_start",
                         ["type": "content_block_start", "index": index, "content_block": ["type": "thinking", "thinking": ""]])
            out += event("content_block_delta",
                         ["type": "content_block_delta", "index": index,
                          "delta": ["type": "thinking_delta", "thinking": "음, 이 이미지는…"]])
            out += event("content_block_stop", ["type": "content_block_stop", "index": index])
            index += 1
        }
        out += event("content_block_start",
                     ["type": "content_block_start", "index": index, "content_block": ["type": "text", "text": ""]])
        for chunk in chunks {
            out += event("content_block_delta",
                         ["type": "content_block_delta", "index": index,
                          "delta": ["type": "text_delta", "text": chunk]])
        }
        out += event("content_block_stop", ["type": "content_block_stop", "index": index])
        out += event("message_delta",
                     ["type": "message_delta", "delta": ["stop_reason": stopReason], "usage": ["output_tokens": 5]])
        out += event("message_stop", ["type": "message_stop"])
        return out
    }

    static func event(_ name: String, _ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }
}
