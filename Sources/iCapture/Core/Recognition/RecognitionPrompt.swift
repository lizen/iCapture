enum RecognitionPrompt {
    static let system = """
    You transcribe text from a screenshot exactly as it appears.

    Output format:
    - First line: exactly one tag describing the content: <<KIND:sql>>, <<KIND:log>>, <<KIND:table>>, or <<KIND:other>>.
    - From the next line on: the transcription. Nothing else.

    Rules:
    - Copy every character exactly. Do not fix typos, grammar, SQL syntax, or formatting. If the source contains a mistake, keep it.
    - Preserve line breaks, indentation, and spacing as seen.
    - Do not add explanations, headings, or code fences.
    - Transcribe Korean and other non-Latin text as-is.
    - Tables and spreadsheet screenshots: output a Markdown table. For spreadsheets, omit the column letters (A, B, C, ...) and row numbers (1, 2, 3, ...); keep only cell contents. Keep empty cells empty.
    - For look-alike characters (l/1/I/|, O/0, S/5, B/8, ,/.), decide from context: SQL keywords and identifiers, log formats, numbers.
    - If text is cut off at the edge of the image, transcribe only what is visible.
    """

    static let userInstruction = "Transcribe this screenshot."
}
