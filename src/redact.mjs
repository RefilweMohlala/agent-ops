// Remove obvious personal data before the text goes anywhere: the AI model, the CRM, queues or logs.
// The member's contact details already live on their CRM record, so nothing is lost.

export function redact(text) {
return String(text)
 .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[EMAIL]")
 .replace(/\b(?:\d[ -]?){12,18}\d\b/g, "[CARD_NUMBER]")

// Phone numbers like 082 555 1234 or +27 82 555 1234. Shaped so dates ("2026-10-03") and year
// ranges don't match.

 .replace(/(?<!\d)(?:\+\d{1,3}[\s-]?)?\(?0?\d{2}\)?[\s-]?\d{3}[\s-]?\d{4}(?!\d)/g, "[PHONE]");
}
 