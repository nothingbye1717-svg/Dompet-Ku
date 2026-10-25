package com.dompetku.dompetku

import java.util.Locale

/** Strict, offline parser: never returns the original notification text. */
internal object TransactionParser {
    data class Result(val amount: Double, val direction: String, val merchant: String)

    private val amountPattern = Regex(
        "(?i)\\b(?:RM|MYR)\\s*([0-9]{1,3}(?:,[0-9]{3})+(?:\\.[0-9]{2})?|[0-9]+(?:\\.[0-9]{2})?)(?![0-9])"
    )
    private val sensitiveOrUnpaid = listOf(
        "otp", "tac", "one-time", "one time", "verification code", "security code",
        "login code", "kod pengesahan", "kata laluan", "password", "passcode",
        "reset code", "auth code", "two-factor", "2fa", "6-digit", "pin number",
        "transaction failed", "payment failed", "unsuccessful", "declined", "rejected",
        "not successful", "not completed", "not paid", "unpaid", "payment pending",
        "payment reminder", "bill due", "due date", "please pay", "payment scheduled"
    )
    private val incomeTerms = listOf(
        "received", "credited", "money in", "incoming transfer", "you receive",
        "you've received", "duit masuk", "telah diterima", "deposit received",
        "refunded", "refund received", "dikreditkan", "telah dikreditkan",
        "transfer received", "pindahan diterima"
    )
    private val expenseTerms = listOf(
        "paid", "debited", "spent", "payment successful", "payment made",
        "purchase successful", "purchased", "withdrawn", "withdrawal successful",
        "transferred to", "sent to", "payment to", "bayaran berjaya",
        "telah dibayar", "telah didebit", "ditolak", "pembayaran berjaya",
        "pindahan kepada", "transfer successful", "transfer completed"
    )

    private fun matchesWordOrPhrase(text: String, phrase: String): Boolean {
        val exact = Regex("(?<![\\p{L}\\p{N}])${Regex.escape(phrase)}(?![\\p{L}\\p{N}])", RegexOption.IGNORE_CASE)
        return exact.containsMatchIn(text)
    }

    fun parse(title: String, body: String): Result? {
        if (body.isBlank() || body.length > 4096 || title.length > 400) return null
        val content = "$title $body"
        val lower = content.lowercase(Locale.ROOT)
        if (sensitiveOrUnpaid.any { matchesWordOrPhrase(lower, it) }) return null

        // Never guess which figure is the transaction when a notification has
        // both the transaction amount and a balance / fee / other RM value.
        val amounts = amountPattern.findAll(content).toList()
        if (amounts.size != 1) return null
        val amount = amounts.first().groupValues[1].replace(",", "").toDoubleOrNull() ?: return null
        if (!amount.isFinite() || amount <= 0.0 || amount > 1_000_000.0) return null

        val incoming = incomeTerms.any { matchesWordOrPhrase(lower, it) }
        val outgoing = expenseTerms.any { matchesWordOrPhrase(lower, it) }
        if (incoming == outgoing) return null

        val maybeMerchant = Regex("(?i)\\b(?:at|to|from|kepada|daripada|di)\\s+([a-z][a-z .&'-]{2,38})")
            .find(body)?.groupValues?.getOrNull(1)?.trim().orEmpty()
        val merchant = maybeMerchant
            .replace(Regex("(?i)\\b(?:account|akaun|your|anda|balance|baki|ending|reference)\\b.*$"), "")
            .trim().take(42)

        return Result(amount, if (incoming) "income" else "expense", merchant)
    }
}
