[CmdletBinding()]
param()

function Test-WdtAllowedW32tmCommand {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$CommandAst)

    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -lt 3) {
        return $false
    }

    $arguments = @($elements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text.Trim("'`"") })
    if ($arguments.Count -eq 2 -and $arguments[0] -eq '/query' -and $arguments[1] -eq '/source') {
        return $true
    }

    return ($arguments.Count -eq 3 -and
        $arguments[0] -eq '/query' -and
        $arguments[1] -eq '/status' -and
        $arguments[2] -eq '/verbose')
}
