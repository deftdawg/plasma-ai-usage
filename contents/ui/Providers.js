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
        var data = JSON.parse(stdout);
        
        // Flatten bucket data for QML ListModel compatibility
        var bucket1 = data.bucket_small || data.buckets?.[0] || {};
        var bucket2 = data.bucket_medium || data.buckets?.[1] || {};
        var bucket3 = data.bucket_large || data.buckets?.[2] || {};
        
        var b1Used = bucket1.used || 0;
        var b1Limit = bucket1.limit || 100;
        var b2Used = bucket2.used || 0;
        var b2Limit = bucket2.limit || 100;
        var b3Used = bucket3.used || 0;
        var b3Limit = bucket3.limit || 100;
        
        return {
            provider: "antigravity",
            name: "Antigravity",
            bucket1Name: bucket1.name || "Small",
            bucket1Used: b1Used,
            bucket1Limit: b1Limit,
            bucket1Percent: b1Limit > 0 ? (b1Used / b1Limit * 100) : 0,
            bucket2Name: bucket2.name || "Medium",
            bucket2Used: b2Used,
            bucket2Limit: b2Limit,
            bucket2Percent: b2Limit > 0 ? (b2Used / b2Limit * 100) : 0,
            bucket3Name: bucket3.name || "Large",
            bucket3Used: b3Used,
            bucket3Limit: b3Limit,
            bucket3Percent: b3Limit > 0 ? (b3Used / b3Limit * 100) : 0,
            valid: true
        };
    } catch (e) {
        console.log("Antigravity: Failed to parse config:", e);
        return null;
    }
}

function parseAmpConfig(stdout) {
    if (stdout.length < 5) return null;
    
    // Check if it's the new text output format
    if (stdout.indexOf("Amp Free:") !== -1 || stdout.indexOf("Individual credits:") !== -1) {
        return parseAmpUsageText(stdout);
    }

    try {
        var data = JSON.parse(stdout);
        
        var freeQuota = data.free_quota || {};
        var credits = data.credits || {};
        
        var freeUsed = freeQuota.used || 0;
        var freeLimit = freeQuota.limit || 10;
        
        return {
            provider: "amp",
            name: "Amp",
            freeUsed: freeUsed,
            freeLimit: freeLimit,
            freePercent: freeLimit > 0 ? (freeUsed / freeLimit * 100) : 0,
            freeResets: freeQuota.resets_at || "",
            creditBalance: credits.balance || 0.00,
            creditCurrency: credits.currency || "USD",
            valid: true
        };
    } catch (e) {
        // Fallback to text parsing if JSON fails
        return parseAmpUsageText(stdout);
    }
}

function parseAmpUsageText(text) {
    try {
        var result = {
            provider: "amp",
            name: "Amp",
            freeUsed: 0,
            freeLimit: 0,
            freePercent: 0,
            freeResets: "",
            creditBalance: 0,
            creditCurrency: "USD",
            valid: true
        };

        // Parse Amp Free: $10.71/$20 remaining (replenishes +$0.83/hour)
        var freeMatch = text.match(/Amp Free: \$([0-9.]+)\/\$([0-9.]+)\s+remaining/);
        if (freeMatch) {
            var remaining = parseFloat(freeMatch[1]);
            var limit = parseFloat(freeMatch[2]);
            result.freeLimit = limit;
            result.freeUsed = limit - remaining;
            result.freePercent = limit > 0 ? (result.freeUsed / limit * 100) : 0;
        }

        // Parse replenishes info
        var resetMatch = text.match(/\(replenishes ([^)]+)\)/);
        if (resetMatch) {
            result.freeResets = resetMatch[1];
        }

        // Parse Individual credits: $77.57 remaining
        var creditMatch = text.match(/Individual credits: \$([0-9.]+)\s+remaining/);
        if (creditMatch) {
            result.creditBalance = parseFloat(creditMatch[1]);
        }

        return result;
    } catch (e) {
        console.log("Amp: Failed to parse text usage:", e);
        return null;
    }
}