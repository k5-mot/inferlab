<#
.SYNOPSIS
download scriptが共通interfaceとcomment規約を満たすことを検証します。
.PARAMETER ScriptPath
検証対象のPowerShell script pathです。
.PARAMETER ExpectedParameters
scriptが公開すべきparameter名の一覧です。
.PARAMETER ExpectedOutputDirectory
script内に定義される出力先directory名です。
.OUTPUTS
値を返しません。
.NOTES
検証違反またはPowerShell構文errorがある場合は例外を送出します。
#>
function Assert-DownloadScript {
    param (
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$ExpectedParameters,
        [string]$ExpectedOutputDirectory
    )

    $ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath,
        [ref]$Tokens,
        [ref]$ParseErrors
    )
    if ($ParseErrors.Count -gt 0) {
        throw "$ScriptPath にPowerShell構文errorがあります: $($ParseErrors.Message -join '; ')"
    }

    $ActualParameters = @(
        $Ast.ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath } |
            Sort-Object
    )
    $ExpectedParameters = @($ExpectedParameters | Sort-Object)
    if (($ActualParameters -join ",") -ne ($ExpectedParameters -join ",")) {
        throw "$ScriptPath の公開引数が不正です: $($ActualParameters -join ', ')"
    }

    foreach ($VariableName in @("Registries", "Packages")) {
        $Assignment = $Ast.FindAll({
            param ($Node)
            $Node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $Node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $Node.Left.VariablePath.UserPath -eq $VariableName -and
                $Node.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $Node.Right.Expression -is [System.Management.Automation.Language.ArrayExpressionAst]
        }, $true)
        if ($Assignment.Count -eq 0) {
            throw "$ScriptPath に配列 '$VariableName' の定義がありません。"
        }
    }

    $StringValues = @(
        $Ast.FindAll({
            param ($Node)
            $Node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object Value
    )
    if ($ExpectedOutputDirectory -and $StringValues -notcontains $ExpectedOutputDirectory) {
        throw "$ScriptPath に出力先directory '$ExpectedOutputDirectory' が定義されていません。"
    }

    $Source = Get-Content -LiteralPath $ScriptPath -Raw
    $Functions = $Ast.FindAll({
        param ($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
    foreach ($Function in $Functions) {
        $Prefix = $Source.Substring(0, $Function.Extent.StartOffset)
        $HelpMatch = [regex]::Match($Prefix, "(?s)<#(?<help>.*?)#>\s*$")
        if (-not $HelpMatch.Success) {
            throw "$ScriptPath のfunction '$($Function.Name)' にdocumentation commentがありません。"
        }

        $Help = $HelpMatch.Groups["help"].Value
        if ($Help -notmatch "(?m)^\.SYNOPSIS\s*$" -or $Help -notmatch "(?m)^\.OUTPUTS\s*$") {
            throw "$ScriptPath のfunction '$($Function.Name)' に目的またはreturn valueの説明がありません。"
        }
        foreach ($Parameter in $Function.Body.ParamBlock.Parameters) {
            $ParameterName = $Parameter.Name.VariablePath.UserPath
            if ($Help -notmatch "(?m)^\.PARAMETER\s+$([regex]::Escape($ParameterName))\s*$") {
                throw "$ScriptPath のfunction '$($Function.Name)' にparameter '$ParameterName' の説明がありません。"
            }
        }
    }
}
