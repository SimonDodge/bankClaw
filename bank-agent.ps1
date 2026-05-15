param(
  [string]$BankId,
  [string]$TaskId,
  [string]$ConfigPath = (Join-Path $PSScriptRoot "banks.json")
)

$baseDir = $PSScriptRoot
$logPath = Join-Path $baseDir "bank-agent.log"

function Write-Log {
  param([string]$Message)
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
  Add-Content -LiteralPath $logPath -Value "[$timestamp] [agent] $Message" -Encoding UTF8
}

function Read-Config {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
  }

  Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-Cdp {
  param(
    [string]$WebSocketUrl,
    [hashtable]$Payload
  )

  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $socket.ConnectAsync([Uri]$WebSocketUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

  try {
    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $socket.SendAsync(
      [ArraySegment[byte]]::new($bytes),
      [System.Net.WebSockets.WebSocketMessageType]::Text,
      $true,
      [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult()

    $buffer = New-Object byte[] 1048576
    $builder = [Text.StringBuilder]::new()

    do {
      $result = $socket.ReceiveAsync(
        [ArraySegment[byte]]::new($buffer),
        [Threading.CancellationToken]::None
      ).GetAwaiter().GetResult()

      if ($result.Count -gt 0) {
        [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
      }
    } while (-not $result.EndOfMessage)

    return $builder.ToString() | ConvertFrom-Json
  } finally {
    if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      $socket.CloseAsync(
        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
        "done",
        [Threading.CancellationToken]::None
      ).GetAwaiter().GetResult()
    }
    $socket.Dispose()
  }
}

function Get-BrowserTab {
  param(
    [object]$Bank
  )

  $port = [int]$Bank.debugPort
  $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 5
  Write-Log "Connected to CDP. Port=$port Tab count=$(@($tabs).Count)"

  $matchUrl = [string]$Bank.matchUrl
  $matchTitle = [string]$Bank.matchTitle

  $tab = $tabs |
    Where-Object {
      $_.type -eq "page" -and (
        ($matchUrl -and $_.url -like "*$matchUrl*") -or
        ($matchTitle -and $_.title -match $matchTitle)
      )
    } |
    Select-Object -First 1

  if (-not $tab) {
    $tab = $tabs | Where-Object { $_.type -eq "page" } | Select-Object -First 1
  }

  if (-not $tab) {
    throw "No inspectable page tab found."
  }

  Write-Log "Using tab. Title=$($tab.title) Url=$($tab.url)"
  $tab
}

function Invoke-PageExpression {
  param(
    [object]$Tab,
    [string]$Expression
  )

  $payload = @{
    id = 1
    method = "Runtime.evaluate"
    params = @{
      expression = $Expression
      returnByValue = $true
      awaitPromise = $true
    }
  }

  $response = Invoke-Cdp -WebSocketUrl $Tab.webSocketDebuggerUrl -Payload $payload
  if ($response.error) {
    throw ($response.error | ConvertTo-Json -Depth 6 -Compress)
  }
  if ($response.result.exceptionDetails) {
    throw ($response.result.exceptionDetails | ConvertTo-Json -Depth 8 -Compress)
  }

  @($response.result.result.value)
}

function New-KeywordScanScript {
  param([string[]]$Keywords)

  $keywordsJson = $Keywords | ConvertTo-Json -Compress
  @"
(() => {
  const keywords = $keywordsJson;
  const textOf = (node) => (node && node.innerText || "").replace(/\s+/g, " ").trim();
  const rows = [];
  const seen = new Set();

  const add = (source, text, href) => {
    if (!text || !keywords.some((keyword) => text.includes(keyword))) return;
    const normalized = text.slice(0, 800);
    const key = source + "|" + normalized + "|" + (href || "");
    if (seen.has(key)) return;
    seen.add(key);
    rows.push({
      source,
      text: normalized,
      href: href || "",
      pageTitle: document.title,
      pageUrl: location.href,
      collectedAt: new Date().toISOString()
    });
  };

  document.querySelectorAll("table tr").forEach((row) => add("table-row", textOf(row), ""));
  document.querySelectorAll("li, .product, .prod, .item, .list-item, [class*='product'], [class*='prod'], [class*='account'], [class*='detail'], [class*='balance']").forEach((node) => {
    const link = node.querySelector("a[href]");
    add("block", textOf(node), link ? link.href : "");
  });
  document.querySelectorAll("a[href], button, input[type='button'], input[type='submit']").forEach((node) => add("action", textOf(node) || node.value || node.title || node.name, node.href || ""));

  if (rows.length === 0) {
    const lines = document.body.innerText
      .split(/\n+/)
      .map((line) => line.replace(/\s+/g, " ").trim())
      .filter((line) => line && keywords.some((keyword) => line.includes(keyword)));
    lines.forEach((line) => add("text-line", line, ""));
  }

  return rows;
})()
"@
}

function New-SnapshotScript {
  @'
(() => {
  const textOf = (node) => (node && node.innerText || "").replace(/\s+/g, " ").trim();
  const rows = [];
  const add = (source, text, extra) => {
    if (!text) return;
    rows.push({
      source,
      text: text.slice(0, 800),
      href: extra || "",
      pageTitle: document.title,
      pageUrl: location.href,
      collectedAt: new Date().toISOString()
    });
  };

  document.querySelectorAll("a[href], button, input[type='button'], input[type='submit']").forEach((node, index) => {
    add("action-" + index, textOf(node) || node.value || node.title || node.name, node.href || node.id || node.name || "");
  });
  document.querySelectorAll("table").forEach((table, index) => add("table-" + index, textOf(table), ""));
  document.querySelectorAll("form").forEach((form, index) => {
    const fields = Array.from(form.querySelectorAll("input, select, textarea")).map((field) => ({
      tag: field.tagName,
      type: field.type || "",
      name: field.name || "",
      id: field.id || "",
      placeholder: field.placeholder || ""
    }));
    add("form-" + index, JSON.stringify(fields), form.id || form.name || "");
  });

  return rows;
})()
'@
}

try {
  $config = Read-Config
  if (-not $BankId) {
    $BankId = [string]$config.defaultBankId
  }

  $bank = @($config.banks) | Where-Object { $_.id -eq $BankId } | Select-Object -First 1
  if (-not $bank) {
    throw "Unknown bank id: $BankId"
  }

  if (-not $TaskId) {
    $TaskId = [string]$bank.tasks[0].id
  }

  $task = @($bank.tasks) | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
  if (-not $task) {
    throw "Unknown task id '$TaskId' for bank '$BankId'"
  }

  Write-Log "Started. Bank=$BankId Task=$TaskId Kind=$($task.kind)"
  $tab = Get-BrowserTab -Bank $bank

  if ($task.kind -eq "snapshot") {
    $expression = New-SnapshotScript
  } else {
    $expression = New-KeywordScanScript -Keywords @($task.keywords)
  }

  $rows = Invoke-PageExpression -Tab $tab -Expression $expression
  Write-Log "Collected row count=$($rows.Count)"

  $prefix = [string]$task.outputPrefix
  if (-not $prefix) {
    $prefix = "$BankId-$TaskId"
  }

  $csvPath = Join-Path $baseDir "$prefix.csv"
  $jsonPath = Join-Path $baseDir "$prefix.json"
  $textPath = Join-Path $baseDir "$prefix.txt"

  $rows |
    Select-Object source, text, href, pageTitle, pageUrl, collectedAt |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

  $rows |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $jsonPath -Encoding UTF8

  if ($rows.Count -eq 0) {
    "No rows were collected for bank=$BankId task=$TaskId." |
      Set-Content -LiteralPath $textPath -Encoding UTF8
  } else {
    $lines = foreach ($row in $rows) {
      "[$($row.source)] $($row.text)`r`n$($row.href)`r`n"
    }
    $lines | Set-Content -LiteralPath $textPath -Encoding UTF8
  }

  Write-Log "Output written. CSV=$csvPath JSON=$jsonPath TXT=$textPath"
  exit 0
} catch {
  Write-Log "Failed: $($_.Exception.Message)"
  exit 1
}
