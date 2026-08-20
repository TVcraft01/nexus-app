package com.example.nexus_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Fetches and caches exchange rates for the math-notes currency conversion
 * (e.g. "10€ in $ ="). The user chose live rates over offline fixed ones.
 *
 * Rates come from a free, keyless API (open.er-api.com, ECB reference rates),
 * fetched once per day and cached in SharedPreferences so the feature still
 * works offline with the last known rates. When the cache is older than a
 * day, the UI shows the date the rates came from — never a silent guess.
 *
 * Rates are NOT secrets and only the 4 supported symbols (EUR, USD, GBP, JPY)
 * are ever stored. No other data is sent or stored.
 */
object CurrencyRates {

    private const val PREFS_NAME = "nexus_currency_rates"
    private const val KEY_JSON = "rates_json"
    private const val STALE_AFTER_MS = 24L * 60 * 60 * 1000
    private const val API_URL = "https://open.er-api.com/v6/latest/EUR"

    /** Symbol → ISO 4217 code. */
    private val symbolToCode = mapOf("€" to "EUR", "$" to "USD", "£" to "GBP", "¥" to "JPY")
    private val supportedCodes = symbolToCode.values.toSet()

    @Volatile
    private var rates: Map<String, Double>? = null

    @Volatile
    private var lastUpdatedMs: Long = 0L

    private var prefs: SharedPreferences? = null
    @Volatile
    private var refreshing = false

    /** Call once at startup with an app Context. */
    fun initialize(context: Context) {
        if (prefs == null) {
            prefs = context.applicationContext
                .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            loadFromCache()
        }
    }

    /** Rate for a currency symbol (e.g. "€" → EUR rate vs. EUR), or null. */
    fun rateFor(symbol: String): Double? {
        val code = symbolToCode[symbol] ?: return null
        return rates?.get(code)?.takeIf { it > 0.0 }
    }

    private fun isStale(): Boolean =
        lastUpdatedMs > 0L && System.currentTimeMillis() - lastUpdatedMs > STALE_AFTER_MS

    /**
     * "rates from Aug 20" when the cached rates are older than a day, else
     * null — shown on the result popup so a stale conversion is never
     * presented as if it were live.
     */
    fun stalenessNote(): String? {
        if (lastUpdatedMs == 0L) return null
        if (!isStale()) return null
        return "rates from ${SimpleDateFormat("MMM d", Locale.getDefault()).format(Date(lastUpdatedMs))}"
    }

    /**
     * Fetches fresh rates in the background if they are missing or stale.
     * Safe to call often: it no-ops while a fetch is already in flight or the
     * cache is still fresh, and offline failures keep whatever cache exists.
     */
    fun refresh() {
        if (prefs == null) return
        if (refreshing) return
        if (rates != null && !isStale()) return
        refreshing = true
        Thread {
            try {
                val conn = URL(API_URL).openConnection() as HttpURLConnection
                try {
                    conn.connectTimeout = 8000
                    conn.readTimeout = 8000
                    conn.requestMethod = "GET"
                    if (conn.responseCode == 200) {
                        val body = conn.inputStream.bufferedReader().use { it.readText() }
                        val json = JSONObject(body)
                        val ratesJson = json.optJSONObject("rates")
                        if (ratesJson != null) {
                            val map = supportedCodes.mapNotNull { code ->
                                val r = ratesJson.optDouble(code, Double.NaN)
                                if (r.isFinite() && r > 0.0) code to r else null
                            }.toMap()
                            if (map.isNotEmpty()) {
                                rates = map
                                lastUpdatedMs = System.currentTimeMillis()
                                persist()
                            }
                        }
                    }
                } finally {
                    conn.disconnect()
                }
            } catch (_: Exception) {
                // Offline or API unreachable: keep whatever cache exists.
            } finally {
                refreshing = false
            }
        }.start()
    }

    private fun loadFromCache() {
        val raw = prefs?.getString(KEY_JSON, null) ?: return
        try {
            val json = JSONObject(raw)
            val ts = json.optLong("ts", 0L)
            val ratesJson = json.optJSONObject("rates") ?: return
            val map = supportedCodes.mapNotNull { code ->
                val r = ratesJson.optDouble(code, Double.NaN)
                if (r.isFinite() && r > 0.0) code to r else null
            }.toMap()
            if (map.isNotEmpty()) {
                rates = map
                lastUpdatedMs = ts
            }
        } catch (_: Exception) {}
    }

    private fun persist() {
        val p = prefs ?: return
        val map: Map<String, Double> = rates ?: emptyMap()
        val json = JSONObject().apply {
            put("ts", lastUpdatedMs)
            put("rates", JSONObject(map))
        }
        p.edit().putString(KEY_JSON, json.toString()).apply()
    }
}
