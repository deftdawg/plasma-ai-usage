

function parseClaudeCredentials(stdout) {
    if (stdout.length < 10) return null;
    try {
        var creds = JSON.parse(stdout);
        var oauth = creds.claudeAiOauth || {};
        if (!oauth.accessToken) return null;
        
        var tier = oauth.rateLimitTier || "default_claude_pro";
        var planMap = {
            "default_claude_pro": "Pro",
            "default_claude_max_5x": "Max 5x",
            "default_claude_max_20x": "Max 20x"
        };
        
        return {
            provider: "claude",
            name: "Claude",
            token: oauth.accessToken,
            plan: planMap[tier] || tier,
            valid: true
        };
    } catch (e) {
        console.log("Claude Usage: Failed to parse credentials:", e);
        return null;
    }
}

function parseAntigravityConfig(stdout) {
    if (stdout.length < 5) return null;
    try {
        // Hypothetical structure based on "3 buckets"
        var data = JSON.parse(stdout);
        return {
            provider: "antigravity",
            name: "Antigravity",
            buckets: [
                { name: "Small", used: data.bucket_small?.used || 0, limit: data.bucket_small?.limit || 100 },
                { name: "Medium", used: data.bucket_medium?.used || 0, limit: data.bucket_medium?.limit || 100 },
                { name: "Large", used: data.bucket_large?.used || 0, limit: data.bucket_large?.limit || 100 }
            ],
            valid: true
        };
    } catch (e) {
        console.log("Antigravity: Failed to parse config:", e);
        return null;
    }
}

function parseAmpConfig(stdout) {
    if (stdout.length < 5) return null;
    try {
        // Hypothetical structure based on "Free quota" and "Credit"
        var data = JSON.parse(stdout);
        return {
            provider: "amp",
            name: "Amp",
            free: {
                used: data.free_quota?.used || 0,
                limit: data.free_quota?.limit || 10,
                resets: data.free_quota?.resets_at
            },
            credit: {
                balance: data.credits?.balance || 0.00,
                currency: data.credits?.currency || "USD"
            },
            valid: true
        };
    } catch (e) {
        console.log("Amp: Failed to parse config:", e);
        return null;
    }
}
