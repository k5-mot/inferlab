$ScriptPath = Join-Path $PSScriptRoot "../Refine-PipPkgs.ps1"
$Tokens = $null
$ParseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$Tokens,
    [ref]$ParseErrors
)
if ($ParseErrors.Count -gt 0) {
    throw "$ScriptPath にPowerShell構文errorがあります: $($ParseErrors.Message -join '; ')"
}

$Source = Get-Content -LiteralPath $ScriptPath -Raw
foreach ($Pattern in @(
    '"--only-binary", ":all:"',
    '"--upgrade"',
    '"--universal"',
    'requirements-full.txt',
    'requirements-next.txt',
    'Test-PinnedRequirementDependencyCompatibility',
    'ConvertTo-MinimumRequirement',
    'x86_64-manylinux_2_34',
    '"windows"'
)) {
    if ($Source -notmatch [regex]::Escape($Pattern)) {
        throw "requirements refinementの必須処理がありません: $Pattern"
    }
}
foreach ($Pattern in @(
    '"--no-binary"',
    '"pip", "install"',
    '"uv", "build"',
    'setup.py',
    'cmake',
    'cargo',
    'cl.exe',
    'msbuild'
)) {
    if ($Source -match [regex]::Escape($Pattern)) {
        throw "requirements refinementがlocal build処理を含んでいます: $Pattern"
    }
}
