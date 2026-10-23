@{
    IncludeDefaultRules = $true
    Severity = @(
        'Error'
        'Warning'
    )
    ExcludeRules = @(
        # Interactive booth script: colored console output is intended.
        'PSAvoidUsingWriteHost'
        # Script-internal helpers, not exported cmdlets; -WhatIf/-Confirm would add no value.
        'PSUseShouldProcessForStateChangingFunctions'
        # Helper names describe collections (alerts, entries, pages); renaming would only churn tests.
        'PSUseSingularNouns'
    )
}
