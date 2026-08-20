package com.example.nexus_app.autofill

import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.view.autofill.AutofillValue
import android.widget.RemoteViews

/**
 * Android AutofillService that supplies saved credentials to login forms.
 *
 * The OS handles showing the autofill picker; Nexus's job is to:
 * 1. Parse the fill request to find username/password fields
 * 2. Look up matching credentials from the vault (via a synchronous cache
 *    populated by the Dart side when the vault is unlocked)
 * 3. Return datasets the OS can present to the user
 *
 * SECURITY: Passwords are never logged, printed, or stored outside secure storage.
 */
class NexusAutofillService : AutofillService() {

    companion object {
        /**
         * In-memory credential cache populated by the Dart side when the vault
         * is unlocked. This avoids calling back into Dart during autofill
         * (which would be too slow for the OS timeout). The cache is cleared
         * when the vault is locked.
         */
        @Volatile
        var credentialCache: List<CredentialEntry> = emptyList()

        fun clearCredentialCache() {
            credentialCache = emptyList()
        }
    }

    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback
    ) {
        val context = request.fillContexts
        val structure = context.last().structure
        val packageName = structure.activityComponent?.packageName ?: ""

        // For now, return all cached credentials that match the package
        // A more sophisticated implementation would parse the structure
        // to find specific username/password fields
        val datasets = mutableListOf<Dataset>()

        for (credential in credentialCache) {
            if (!matchesCredential(credential, packageName)) continue

            // Create a dataset with the credential
            // The OS will handle showing this to the user
            val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                setTextViewText(android.R.id.text1, "${credential.username} (${credential.name})")
            }

            val builder = Dataset.Builder(presentation)

            // Note: Without structure traversal, we can't set specific autofill IDs
            // The OS will still show the credential as an option
            datasets.add(builder.build())
        }

        if (datasets.isEmpty()) {
            callback.onSuccess(null)
            return
        }

        val responseBuilder = FillResponse.Builder()
        for (dataset in datasets) {
            responseBuilder.addDataset(dataset)
        }

        callback.onSuccess(responseBuilder.build())
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        // We don't auto-save from autofill — the user manages entries
        // explicitly in the vault UI. This is a deliberate security choice.
        callback.onSuccess()
    }

    private fun matchesCredential(
        credential: CredentialEntry,
        packageName: String
    ): Boolean {
        // Match if the credential's site name appears in the package name
        // or the package name appears in the credential's site name
        val siteLower = credential.name.lowercase()
        val pkgLower = packageName.lowercase()

        return pkgLower.contains(siteLower) ||
                siteLower.contains(pkgLower)
    }

    /**
     * Simple data class for the credential cache.
     * Passwords are held in memory only and never logged.
     */
    data class CredentialEntry(
        val name: String,
        val username: String,
        val password: String
    )
}
