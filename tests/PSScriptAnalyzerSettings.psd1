@{
    Severity = @('Error','Warning')

    # Rules we enforce strictly. PSScriptAnalyzer's full default rule set runs
    # in addition; this list is the project-specific intersection that we
    # never want to regress, called out for visibility.
    IncludeRules = @(
        'PSAvoidUsingEmptyCatchBlock',
        'PSAvoidGlobalVars',
        'PSAvoidUsingComputerNameHardcoded',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUserNameAndPasswordParams',
        'PSAvoidUsingWMICmdlet',
        'PSReservedCmdletChar',
        'PSReservedParams',
        'PSUseCmdletCorrectly',
        'PSUsePSCredentialType',
        'PSUseSingularNouns',
        'PSUseToExportFieldsInManifest',
        'PSUseUTF8EncodingForHelpFile',
        'PSAvoidTrailingWhitespace',
        'PSPossibleIncorrectComparisonWithNull',
        'PSPossibleIncorrectUsageOfRedirectionOperator',
        'PSPossibleIncorrectUsageOfAssignmentOperator'
    )

    # Suppress positional-parameter noise for cmdlets where positional usage
    # is universally idiomatic. PSUseDeclaredVarsMoreThanAssignments is
    # excluded because PowerShell closures captured by '& $module { ... }
    # $value' produce false positives the analyzer cannot see through --
    # the captured variable IS used, just inside a script-block body that
    # PSScriptAnalyzer treats as a separate scope.
    ExcludeRules = @(
        'PSAvoidUsingPositionalParameters',
        'PSUseDeclaredVarsMoreThanAssignments'
    )

    Rules = @{
        # Be strict about secrets even in tests / docs.
        PSAvoidUsingPlainTextForPassword = @{ Enable = $true }
    }
}
