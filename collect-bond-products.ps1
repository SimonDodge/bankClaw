param(
  [string]$BankId = "icbc",
  [string]$TaskId = "bond-products"
)

$agentPath = Join-Path $PSScriptRoot "bank-agent.ps1"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agentPath -BankId $BankId -TaskId $TaskId
exit $LASTEXITCODE
